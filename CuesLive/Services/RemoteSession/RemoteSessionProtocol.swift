import Foundation
import Network

enum RemoteSessionFraming {
    static let headerSize = 4
    static let maxPayloadSize = 8 * 1024 * 1024

    static func encode(_ message: RemoteSessionMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(RemoteSessionWireBox(message: message))
        guard payload.count <= maxPayloadSize else {
            throw RemoteSessionError.payloadTooLarge
        }
        var frame = Data(count: headerSize + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.replaceSubrange(0..<headerSize, with: $0) }
        frame.replaceSubrange(headerSize..<frame.count, with: payload)
        return frame
    }

    static func decodeMessage(from payload: Data) throws -> RemoteSessionMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteSessionWireBox.self, from: payload).message
    }

    static func makeTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// Stable JSON envelope so iOS/macOS never disagree on enum associated-value coding keys.
struct RemoteSessionWireBox: Codable {
    var message: RemoteSessionMessage

    private enum Kind: String, Codable {
        case hello
        case auth
        case authResult
        case snapshot
        case state
        case command
        case ping
        case pong
        case error
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case protocolVersion
        case displayName
        case pin
        case success
        case message
        case snapshot
        case state
        case command
    }

    init(message: RemoteSessionMessage) {
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .hello:
            message = .hello(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                displayName: try container.decode(String.self, forKey: .displayName)
            )
        case .auth:
            message = .auth(pin: try container.decode(String.self, forKey: .pin))
        case .authResult:
            message = .authResult(
                success: try container.decode(Bool.self, forKey: .success),
                message: try container.decodeIfPresent(String.self, forKey: .message)
            )
        case .snapshot:
            message = .snapshot(try container.decode(RemoteSessionSnapshot.self, forKey: .snapshot))
        case .state:
            message = .state(try container.decode(RemoteSessionState.self, forKey: .state))
        case .command:
            message = .command(try container.decode(RemoteSessionCommand.self, forKey: .command))
        case .ping:
            message = .ping
        case .pong:
            message = .pong
        case .error:
            message = .error(try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch message {
        case .hello(let protocolVersion, let displayName):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(displayName, forKey: .displayName)
        case .auth(let pin):
            try container.encode(Kind.auth, forKey: .kind)
            try container.encode(pin, forKey: .pin)
        case .authResult(let success, let message):
            try container.encode(Kind.authResult, forKey: .kind)
            try container.encode(success, forKey: .success)
            try container.encodeIfPresent(message, forKey: .message)
        case .snapshot(let snapshot):
            try container.encode(Kind.snapshot, forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case .state(let state):
            try container.encode(Kind.state, forKey: .kind)
            try container.encode(state, forKey: .state)
        case .command(let command):
            try container.encode(Kind.command, forKey: .kind)
            try container.encode(command, forKey: .command)
        case .ping:
            try container.encode(Kind.ping, forKey: .kind)
        case .pong:
            try container.encode(Kind.pong, forKey: .kind)
        case .error(let message):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

enum RemoteSessionError: LocalizedError {
    case payloadTooLarge
    case notConnected
    case authenticationFailed(String)
    case sessionBusy
    case encodingFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge:
            "Remote session message is too large."
        case .notConnected:
            "Not connected to a remote session."
        case .authenticationFailed(let message):
            message
        case .sessionBusy:
            "Host already has a remote client connected."
        case .encodingFailed:
            "Failed to encode remote session message."
        case .cancelled:
            "Remote session cancelled."
        }
    }
}

/// Accumulates length-prefixed frames from an `NWConnection`.
final class RemoteSessionConnectionReader {
    private var buffer = Data()
    private let onMessage: (RemoteSessionMessage) -> Void
    private let onFailure: (Error) -> Void

    init(
        onMessage: @escaping (RemoteSessionMessage) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.onMessage = onMessage
        self.onFailure = onFailure
    }

    func append(_ data: Data) {
        buffer.append(data)
        drain()
    }

    private func drain() {
        while true {
            guard buffer.count >= RemoteSessionFraming.headerSize else { return }
            let length = buffer.prefix(RemoteSessionFraming.headerSize).reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            let payloadLength = Int(length)
            guard payloadLength >= 0, payloadLength <= RemoteSessionFraming.maxPayloadSize else {
                onFailure(RemoteSessionError.payloadTooLarge)
                buffer.removeAll(keepingCapacity: false)
                return
            }
            let total = RemoteSessionFraming.headerSize + payloadLength
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(in: RemoteSessionFraming.headerSize..<total)
            buffer.removeSubrange(0..<total)
            do {
                let message = try RemoteSessionFraming.decodeMessage(from: payload)
                onMessage(message)
            } catch {
                onFailure(error)
                return
            }
        }
    }
}

extension NWConnection {
    func sendRemoteMessage(_ message: RemoteSessionMessage, completion: ((Error?) -> Void)? = nil) {
        do {
            let data = try RemoteSessionFraming.encode(message)
            // TCP is stream-oriented; `.defaultMessage` can fail to deliver across platforms.
            send(
                content: data,
                contentContext: .defaultStream,
                isComplete: false,
                completion: .contentProcessed { error in
                    completion?(error)
                }
            )
        } catch {
            completion?(error)
        }
    }

    func receiveRemoteFrames(
        reader: RemoteSessionConnectionReader,
        onClosed: @escaping () -> Void
    ) {
        receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            if let content, !content.isEmpty {
                reader.append(content)
            }
            if isComplete || error != nil {
                onClosed()
                return
            }
            self?.receiveRemoteFrames(reader: reader, onClosed: onClosed)
        }
    }
}
