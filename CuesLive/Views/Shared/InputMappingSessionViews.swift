import SwiftUI

struct InputMappingToolbarMenu: View {
    @Environment(InputMappingController.self) private var mapping

    var body: some View {
        Menu {
            Button {
                mapping.toggleKeyMapping()
            } label: {
                Label(
                    mapping.session == .keyMapping ? "Done Key Mapping" : "Key Mapping",
                    systemImage: "keyboard"
                )
            }

            Button {
                mapping.toggleMIDIMapping()
            } label: {
                Label(
                    mapping.session == .midiMapping ? "Done MIDI Mapping" : "MIDI Mapping",
                    systemImage: "pianokeys"
                )
            }
        } label: {
            Label("Mapping", systemImage: mappingIcon)
                .labelStyle(.iconOnly)
        }
        .tint(mapping.isMapping ? AppColors.accent : nil)
        .help("MIDI and Key Mapping")
        .accessibilityLabel("MIDI and Key Mapping")
    }

    private var mappingIcon: String {
        switch mapping.session {
        case .keyMapping: "keyboard.fill"
        case .midiMapping: "pianokeys"
        case .idle: "keyboard"
        }
    }
}

struct LiveInputMappingSessionModifier: ViewModifier {
    let handler: (MappableLiveAction) -> Void
    var arePlaybackActionsEnabled: Bool = true

    @Environment(InputMappingController.self) private var mapping
    @State private var sessionToken: UUID?
    #if os(iOS)
    @FocusState private var isFocused: Bool
    #endif

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                guard let binding = KeyBinding(keyPress: press) else { return .ignored }
                return mapping.handleKey(binding) ? .handled : .ignored
            }
            #endif
            .onAppear {
                sessionToken = mapping.activateLiveSession(handler: handler)
                mapping.arePlaybackActionsEnabled = arePlaybackActionsEnabled
                #if os(iOS)
                isFocused = true
                #endif
            }
            .onDisappear {
                if let sessionToken {
                    mapping.deactivateLiveSession(token: sessionToken)
                }
            }
            .onChange(of: arePlaybackActionsEnabled) { _, enabled in
                mapping.arePlaybackActionsEnabled = enabled
            }
            #if os(iOS)
            .onChange(of: mapping.isMapping) { _, isMapping in
                if isMapping {
                    isFocused = true
                }
            }
            #endif
    }
}

extension View {
    func liveInputMappingSession(
        arePlaybackActionsEnabled: Bool = true,
        handler: @escaping (MappableLiveAction) -> Void
    ) -> some View {
        modifier(
            LiveInputMappingSessionModifier(
                handler: handler,
                arePlaybackActionsEnabled: arePlaybackActionsEnabled
            )
        )
    }
}
