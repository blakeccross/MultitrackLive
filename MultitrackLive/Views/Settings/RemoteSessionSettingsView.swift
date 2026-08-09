import SwiftUI

struct RemoteSessionSettingsView: View {
    @Bindable private var settings = RemoteSessionSettingsStore.shared
    @Bindable private var host = RemoteSessionHostService.shared
    @Bindable private var client = RemoteSessionClientService.shared
    private let hostSession = RemoteHostSessionController.shared

    @State private var pinDraft = ""
    @State private var selectedPeer: RemoteSessionPeer?
    @State private var showingPINPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                hostSection
                joinSection
            }
            .padding(AppSpacing.lg)
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundSecondary)
        .onAppear {
            hostSession.syncAdvertising()
            if case .idle = client.phase {
                client.startBrowsing()
            }
        }
        .onDisappear {
            if !client.isConnected {
                client.stopBrowsing()
            }
        }
        .onChange(of: settings.isHostingEnabled) { _, _ in
            hostSession.syncAdvertising()
        }
        .onChange(of: settings.pin) { _, _ in
            hostSession.syncAdvertising()
        }
        .onChange(of: settings.displayName) { _, _ in
            hostSession.syncAdvertising()
        }
        .alert("Enter Password", isPresented: $showingPINPrompt) {
            TextField("4-digit password", text: $pinDraft)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Connect") {
                // Defer so iOS commits the alert TextField into `pinDraft` first.
                DispatchQueue.main.async {
                    connectWithPIN()
                }
            }
            Button("Cancel", role: .cancel) {
                selectedPeer = nil
                pinDraft = ""
            }
        } message: {
            if let selectedPeer {
                Text("Enter the password shown on \(selectedPeer.name).")
            } else {
                Text("Enter the host password.")
            }
        }
    }

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Host Remote Session")

            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Toggle("Allow Remote Control", isOn: Binding(
                    get: { settings.isHostingEnabled },
                    set: { enabled in
                        hostSession.setHostingEnabled(enabled)
                    }
                ))

                LabeledContent("Device Name") {
                    TextField("Name", text: $settings.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }

                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Password")
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                        Text(settings.pin)
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .tracking(4)
                    }

                    Spacer()

                    Button("Regenerate") {
                        settings.regeneratePIN()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!settings.isHostingEnabled)
                }

                if settings.isHostingEnabled {
                    statusRow(
                        title: host.isClientAuthenticated
                            ? "Connected\(host.connectedClientName.map { " · \($0)" } ?? "")"
                            : (host.statusMessage ?? "Advertising on local network")
                    )
                    if host.isClientConnected {
                        Button("Disconnect Client", role: .destructive) {
                            hostSession.disconnectClient()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }

    private var joinSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            AppSectionHeader(title: "Join Remote Session")

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                if client.isConnected {
                    statusRow(title: "Connected to \(client.hostDisplayName ?? "host")")
                    if client.snapshot == nil {
                        Text("Waiting for setlist from host…")
                            .font(.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Button("Disconnect", role: .destructive) {
                        client.disconnect()
                        client.startBrowsing()
                    }
                    .buttonStyle(.bordered)
                } else {
                    if let status = client.phase.statusText,
                       client.phase != .browsing,
                       client.phase != .idle {
                        statusRow(title: status)
                    }

                    if let lastError = client.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    switch client.phase {
                    case .connecting, .authenticating:
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Cancel") {
                            client.disconnect()
                            client.startBrowsing()
                        }
                        .buttonStyle(.bordered)
                    default:
                        if client.discoveredPeers.isEmpty {
                            Text("Searching for hosts on this network…")
                                .font(.callout)
                                .foregroundStyle(AppColors.textSecondary)
                        } else {
                            ForEach(client.discoveredPeers) { peer in
                                Button {
                                    selectedPeer = peer
                                    pinDraft = ""
                                    showingPINPrompt = true
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(peer.name)
                                                .foregroundStyle(AppColors.textPrimary)
                                            Text("Available")
                                                .font(.caption)
                                                .foregroundStyle(AppColors.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(AppColors.textTertiary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button("Refresh") {
                            client.startBrowsing()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(AppSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
    }

    private func statusRow(title: String) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(AppColors.accent)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.callout)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private func connectWithPIN() {
        guard let selectedPeer else { return }
        let pin = pinDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RemoteSessionSettingsStore.isValidPIN(pin) else {
            client.reportLocalError("Enter the \(RemoteSessionBonjour.pinLength)-digit password")
            return
        }
        client.connect(to: selectedPeer, pin: pin)
        self.selectedPeer = nil
        pinDraft = ""
    }
}
