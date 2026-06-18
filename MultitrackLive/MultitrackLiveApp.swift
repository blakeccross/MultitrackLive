import SwiftData
import SwiftUI

@main
struct MultitrackLiveApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try PersistenceController.makeContainer()
        } catch {
            fatalError("Could not initialize app storage: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .commands {
            SongMenuCommands()
        }
        #endif
    }
}

struct SongEditorActions {
    var canAutoGroup = false
    var autoGroup: () -> Void = {}
    var importAbleton: () -> Void = {}
}

private struct SongEditorActionsKey: FocusedValueKey {
    typealias Value = SongEditorActions
    static var defaultValue: Value? { nil }
}

extension FocusedValues {
    var songEditorActions: SongEditorActions? {
        get { self[SongEditorActionsKey.self] }
        set { self[SongEditorActionsKey.self] = newValue }
    }
}

#if os(macOS)
struct SongMenuCommands: Commands {
    @FocusedValue(\.songEditorActions) private var actions

    var body: some Commands {
        CommandMenu("Song") {
            Button("Auto Group") {
                actions?.autoGroup()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(actions?.canAutoGroup != true)

            Button("Add Ableton File…") {
                actions?.importAbleton()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }
    }
}
#endif
