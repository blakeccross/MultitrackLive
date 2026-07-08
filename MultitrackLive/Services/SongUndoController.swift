import Foundation
import Observation

@Observable
final class SongUndoController: NSObject {
    private let undoManager = UndoManager()
    private(set) var isApplyingUndo = false

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var undoActionName: String? { undoManager.undoActionName }
    var redoActionName: String? { undoManager.redoActionName }

    override init() {
        super.init()
        undoManager.levelsOfUndo = 50
    }

    func registerChange(
        actionName: String,
        before: SongEditSnapshot,
        after: SongEditSnapshot,
        apply: @escaping (SongEditSnapshot) -> Void
    ) {
        guard before != after else { return }
        guard !isApplyingUndo else { return }

        undoManager.registerUndo(withTarget: self) { target in
            target.applySnapshot(before, actionName: actionName, paired: after, using: apply)
        }
        undoManager.setActionName(actionName)
    }

    func undo() {
        undoManager.undo()
    }

    func redo() {
        undoManager.redo()
    }

    private func applySnapshot(
        _ snapshot: SongEditSnapshot,
        actionName: String,
        paired: SongEditSnapshot,
        using apply: @escaping (SongEditSnapshot) -> Void
    ) {
        isApplyingUndo = true
        apply(snapshot)
        isApplyingUndo = false

        undoManager.registerUndo(withTarget: self) { target in
            target.applySnapshot(paired, actionName: actionName, paired: snapshot, using: apply)
        }
        undoManager.setActionName(actionName)
    }
}
