import Foundation
import Network
import Observation

@MainActor
@Observable
final class RemoteSessionHostService {
    static let shared = RemoteSessionHostService()

    private(set) var isAdvertising = false
    private(set) var isClientConnected = false
    private(set) var isClientAuthenticated = false
    private(set) var statusMessage: String?
    private(set) var connectedClientName: String?

    var onCommand: ((RemoteSessionCommand) -> Void)?
    var snapshotProvider: (() -> RemoteSessionSnapshot?)?
    var stateProvider: (() -> RemoteSessionState?)?
    /// Host controller supplies live-UI binding status for user-facing wait messages.
    var isLiveUIBoundProvider: (() -> Bool)?
    /// Called on snapshot retry ticks so the controller can rebuild cache without
    /// the transport reaching into the session singleton.
    var onSnapshotRetryTick: (() -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var reader: RemoteSessionConnectionReader?
    private var expectedPIN = ""
    private var displayName = ""
    private var instanceID = ""
    private var statePushTask: Task<Void, Never>?
    private var pendingConnection: NWConnection?
    private var authTimeoutTask: Task<Void, Never>?
    private var snapshotRetryTask: Task<Void, Never>?
    private(set) var hasSentSnapshot = false
    private var snapshotAttemptCount = 0

    /// Serializes TCP writes so length-prefixed frames never interleave.
    private var outboundQueue: [(data: Data, completion: ((Error?) -> Void)?)] = []
    private var isWriting = false

    private init() {}

    func startAdvertising(pin: String, displayName: String, instanceID: String) {
        // Keep an active client session alive — restarting the listener drops TCP.
        if listener != nil, isAdvertising {
            expectedPIN = pin
            self.displayName = displayName
            self.instanceID = instanceID
            if !isClientConnected {
                statusMessage = "Waiting for a client…"
            }
            return
        }

        stopAdvertising()
        expectedPIN = pin
        self.displayName = displayName
        self.instanceID = instanceID
        statusMessage = nil

        do {
            let parameters = RemoteSessionFraming.makeTCPParameters()
            let listener = try NWListener(using: parameters)
            var txtRecord = NWTXTRecord()
            txtRecord[RemoteSessionBonjour.instanceIDTXTKey] = instanceID
            listener.service = NWListener.Service(
                name: displayName,
                type: RemoteSessionBonjour.serviceType,
                txtRecord: txtRecord
            )
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            isAdvertising = true
            statusMessage = "Waiting for a client…"
        } catch {
            statusMessage = error.localizedDescription
            isAdvertising = false
        }
    }

    func stopAdvertising() {
        resetSessionState(clearStatus: true)
        listener?.cancel()
        listener = nil
        isAdvertising = false
        statusMessage = nil
    }

    func pushSnapshot() {
        pushSnapshot(isInitialDelivery: !hasSentSnapshot)
    }

    /// - Parameter isInitialDelivery: Only the first post-auth snapshot uses retry/drop-on-failure.
    ///   Later setlist edits must never disconnect the client.
    func pushSnapshot(isInitialDelivery: Bool) {
        guard isClientAuthenticated, connection != nil else { return }

        if isInitialDelivery {
            snapshotAttemptCount += 1
        }

        guard let snapshot = snapshotProvider?() else {
            guard isInitialDelivery else {
                statusMessage = "Client connected — setlist update skipped (not ready)"
                return
            }
            let bound = isLiveUIBoundProvider?() ?? false
            statusMessage = bound
                ? "Client connected — building setlist…"
                : "Client connected — open the live setlist on this Mac"
            startSnapshotRetryLoop()
            if snapshotAttemptCount >= 5 {
                let message = bound
                    ? "Host could not build the setlist snapshot. Try selecting the setlist again on the host."
                    : "Host live setlist is not active. Keep cues.live open on the setlist screen, then reconnect."
                enqueue(.error(message)) { [weak self] _ in
                    self?.statusMessage = message
                    self?.dropClient()
                }
            }
            return
        }

        enqueue(.snapshot(snapshot)) { [weak self] error in
            guard let self else { return }
            if let error {
                self.statusMessage = "Snapshot send failed: \(error.localizedDescription)"
                if isInitialDelivery {
                    self.startSnapshotRetryLoop()
                    if self.snapshotAttemptCount >= 5 {
                        let message = "Failed to send setlist to remote: \(error.localizedDescription)"
                        self.enqueue(.error(message)) { _ in
                            self.statusMessage = message
                            self.dropClient()
                        }
                    }
                }
                return
            }

            let wasInitial = !self.hasSentSnapshot
            self.hasSentSnapshot = true
            self.snapshotAttemptCount = 0
            self.snapshotRetryTask?.cancel()
            self.snapshotRetryTask = nil
            self.statusMessage = "Client connected"
            if wasInitial {
                self.startStatePushLoop()
            }
        }
    }

    func retrySnapshotIfNeeded() {
        guard isClientAuthenticated, !hasSentSnapshot else { return }
        pushSnapshot(isInitialDelivery: true)
    }

    func pushState() {
        guard isClientAuthenticated, hasSentSnapshot, connection != nil else { return }
        // Avoid unbounded backlog while song loads / UI thrash — keep the freshest state.
        guard outboundQueue.count < 8 else { return }
        guard let state = stateProvider?() else { return }
        enqueue(.state(state))
    }

    private func startSnapshotRetryLoop() {
        guard snapshotRetryTask == nil else { return }
        snapshotRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 750_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isClientAuthenticated, !self.hasSentSnapshot else { return }
                // Ask the session controller to rebuild cache / retry push.
                self.onSnapshotRetryTick?()
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isAdvertising = true
            if !isClientConnected {
                statusMessage = "Waiting for a client…"
            }
        case .failed(let error):
            statusMessage = error.localizedDescription
            isAdvertising = false
        case .cancelled:
            isAdvertising = false
        default:
            break
        }
    }

    private func handleNewConnection(_ newConnection: NWConnection) {
        if isClientConnected || pendingConnection != nil {
            // Best-effort busy signal on the rejected socket.
            newConnection.start(queue: .main)
            if let data = try? RemoteSessionFraming.encode(
                .error(RemoteSessionError.sessionBusy.localizedDescription)
            ) {
                newConnection.send(
                    content: data,
                    contentContext: .defaultStream,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        newConnection.cancel()
                    }
                )
            } else {
                newConnection.cancel()
            }
            return
        }

        pendingConnection = newConnection
        attach(to: newConnection, authenticated: false)
        scheduleAuthTimeout()
        enqueue(.hello(
            protocolVersion: RemoteSessionBonjour.protocolVersion,
            displayName: displayName
        ))
    }

    private func scheduleAuthTimeout() {
        authTimeoutTask?.cancel()
        authTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.isClientConnected, !self.isClientAuthenticated else { return }
            self.statusMessage = "Authentication timed out"
            self.dropClient()
        }
    }

    private func attach(to connection: NWConnection, authenticated: Bool) {
        self.connection = connection
        isClientConnected = true
        isClientAuthenticated = authenticated
        outboundQueue.removeAll()
        isWriting = false

        let reader = RemoteSessionConnectionReader(
            onMessage: { [weak self] message in
                Task { @MainActor in
                    self?.handleMessage(message)
                }
            },
            onFailure: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    // A single bad frame must not kick an authenticated client.
                    if self.isClientAuthenticated {
                        self.statusMessage = "Ignored bad remote frame: \(error.localizedDescription)"
                        return
                    }
                    self.statusMessage = error.localizedDescription
                    self.dropClient()
                }
            }
        )
        self.reader = reader

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }
        connection.start(queue: .main)
        connection.receiveRemoteFrames(reader: reader) { [weak self] in
            Task { @MainActor in
                self?.dropClient()
            }
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            statusMessage = isClientAuthenticated
                ? (hasSentSnapshot ? "Client connected" : "Sending setlist…")
                : "Authenticating…"
            pumpOutboundQueue()
        case .failed(let error):
            statusMessage = error.localizedDescription
            dropClient()
        case .cancelled:
            // Only drop when this connection is still the active one.
            // Replacing/restarting advertising must not race-cancel an unrelated socket.
            if connection != nil {
                dropClient()
            }
        default:
            break
        }
    }

    private func handleMessage(_ message: RemoteSessionMessage) {
        switch message {
        case .hello(_, let name):
            connectedClientName = name
        case .auth(let pin):
            handleAuth(pin: pin)
        case .command(let command):
            guard isClientAuthenticated else { return }
            onCommand?(command)
        case .ping:
            enqueue(.pong)
        case .pong, .authResult, .snapshot, .state, .error:
            break
        }
    }

    private func handleAuth(pin: String) {
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        let success = trimmed == expectedPIN
        if success {
            authTimeoutTask?.cancel()
            authTimeoutTask = nil
            pendingConnection = nil
            isClientAuthenticated = true
            hasSentSnapshot = false
            snapshotAttemptCount = 0
            statusMessage = "Sending setlist…"
            enqueue(.authResult(success: true, message: nil)) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.statusMessage = error.localizedDescription
                    self.dropClient()
                    return
                }
                self.pushSnapshot()
                self.startSnapshotRetryLoop()
            }
        } else {
            enqueue(.authResult(success: false, message: "Incorrect password")) { [weak self] _ in
                self?.dropClient()
            }
        }
    }

    private func startStatePushLoop() {
        statePushTask?.cancel()
        statePushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pushState()
                try? await Task.sleep(nanoseconds: 100_000_000) // 10 Hz
            }
        }
    }

    private func enqueue(
        _ message: RemoteSessionMessage,
        completion: ((Error?) -> Void)? = nil
    ) {
        do {
            let data = try RemoteSessionFraming.encode(message)
            outboundQueue.append((data, completion))
            pumpOutboundQueue()
        } catch {
            statusMessage = "Encode failed: \(error.localizedDescription)"
            completion?(error)
        }
    }

    private func pumpOutboundQueue() {
        guard !isWriting else { return }
        guard let connection, connection.state == .ready else { return }
        guard !outboundQueue.isEmpty else { return }

        isWriting = true
        let item = outboundQueue.removeFirst()
        connection.send(
            content: item.data,
            contentContext: .defaultStream,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.isWriting = false
                    item.completion?(error)
                    if error != nil {
                        self.outboundQueue.removeAll()
                        return
                    }
                    self.pumpOutboundQueue()
                }
            }
        )
    }

    private func dropClient() {
        resetSessionState(clearStatus: false)
        if isAdvertising {
            statusMessage = "Waiting for a client…"
        }
    }

    private func resetSessionState(clearStatus: Bool) {
        authTimeoutTask?.cancel()
        authTimeoutTask = nil
        snapshotRetryTask?.cancel()
        snapshotRetryTask = nil
        statePushTask?.cancel()
        statePushTask = nil
        pendingConnection?.cancel()
        pendingConnection = nil
        connection?.cancel()
        connection = nil
        reader = nil
        outboundQueue.removeAll()
        isWriting = false
        isClientConnected = false
        isClientAuthenticated = false
        connectedClientName = nil
        hasSentSnapshot = false
        snapshotAttemptCount = 0
        if clearStatus {
            statusMessage = nil
        }
    }
}
