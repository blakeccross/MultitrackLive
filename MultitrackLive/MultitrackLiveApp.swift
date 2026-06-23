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
        .windowToolbarStyle(.expanded)
        .commands {
            FileMenuCommands()
            SongMenuCommands()
            ClipEditorCommands()
        }
        #endif
    }
}

struct LiveSetlistActions {
    var canSave = false
    var save: () -> Void = {}
    var canNew = false
    var newSetlist: () -> Void = {}
}

struct SongEditorActions {
    var canAutoGroup = false
    var autoGroup: () -> Void = {}
    var importAbleton: () -> Void = {}
}

struct ClipEditorActions {
    var canSplit = false
    var canJoin = false
    var split: () -> Void = {}
    var join: () -> Void = {}
}

private struct LiveSetlistActionsKey: FocusedValueKey {
    typealias Value = LiveSetlistActions
    static var defaultValue: Value? { nil }
}

private struct SongEditorActionsKey: FocusedValueKey {
    typealias Value = SongEditorActions
    static var defaultValue: Value? { nil }
}

private struct ClipEditorActionsKey: FocusedValueKey {
    typealias Value = ClipEditorActions
    static var defaultValue: Value? { nil }
}

extension FocusedValues {
    var liveSetlistActions: LiveSetlistActions? {
        get { self[LiveSetlistActionsKey.self] }
        set { self[LiveSetlistActionsKey.self] = newValue }
    }

    var songEditorActions: SongEditorActions? {
        get { self[SongEditorActionsKey.self] }
        set { self[SongEditorActionsKey.self] = newValue }
    }

    var clipEditorActions: ClipEditorActions? {
        get { self[ClipEditorActionsKey.self] }
        set { self[ClipEditorActionsKey.self] = newValue }
    }
}

#if os(macOS)
struct FileMenuCommands: Commands {
    @FocusedValue(\.liveSetlistActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                actions?.newSetlist()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions?.canNew != true)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                actions?.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(actions?.canSave != true)
        }
    }
}

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

struct ClipEditorCommands: Commands {
    @FocusedValue(\.clipEditorActions) private var actions

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Split at Edit Point") {
                actions?.split()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(actions?.canSplit != true)

            Button("Join with Next Region") {
                actions?.join()
            }
            .keyboardShortcut("j", modifiers: .command)
            .disabled(actions?.canJoin != true)
        }
    }
}
#endif
