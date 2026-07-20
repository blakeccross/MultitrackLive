import SwiftData
import SwiftUI

#if os(macOS)
private enum AppWindowMetrics {
    static let minimumWidth: CGFloat = 960
    static let minimumHeight: CGFloat = 600
    static let defaultWidth: CGFloat = 1280
    static let defaultHeight: CGFloat = 800
}
#endif

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
                #if os(macOS)
                .frame(
                    minWidth: AppWindowMetrics.minimumWidth,
                    minHeight: AppWindowMetrics.minimumHeight
                )
                #endif
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .defaultSize(
            width: AppWindowMetrics.defaultWidth,
            height: AppWindowMetrics.defaultHeight
        )
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.expanded)
        .commands {
            FileMenuCommands()
            SongMenuCommands()
            SongUndoCommands()
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
    var canExportPackage = false
    var exportPackage: () -> Void = {}
    var canOpenPackage = false
    var openPackage: () -> Void = {}
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

struct SongUndoActions {
    var canUndo = false
    var canRedo = false
    var undoActionName: String?
    var redoActionName: String?
    var undo: () -> Void = {}
    var redo: () -> Void = {}
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

private struct SongUndoActionsKey: FocusedValueKey {
    typealias Value = SongUndoActions
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

    var songUndoActions: SongUndoActions? {
        get { self[SongUndoActionsKey.self] }
        set { self[SongUndoActionsKey.self] = newValue }
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

            Button("Export Setlist Folder…") {
                actions?.exportPackage()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(actions?.canExportPackage != true)

            Divider()

            Button("Open Setlist Folder…") {
                actions?.openPackage()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(actions?.canOpenPackage != true)
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

struct SongUndoCommands: Commands {
    @FocusedValue(\.songUndoActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(actions?.undoActionName.map { "Undo \($0)" } ?? "Undo") {
                actions?.undo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(actions?.canUndo != true)

            Button(actions?.redoActionName.map { "Redo \($0)" } ?? "Redo") {
                actions?.redo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(actions?.canRedo != true)
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
