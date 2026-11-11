import Foundation

/// The undo history of one open document. It owns the two stacks, the last
/// recorded state and the clean baseline.
///
/// The editor still owns everything around a step: the 350 ms coalescing timer,
/// the busy guards, status tokens, applying a restored state to the published
/// values and reloading pixels after a crop or turn. The editor supplies the
/// current state at each explicit transaction boundary. This type only decides
/// what a boundary does to history.
///
/// It is a value type so the transitions are testable without a model or a
/// window, and so two histories can never share a stack.
struct DocumentSession {
    /// A gesture that keeps editing forever must not grow memory without bound.
    static let stepLimit = 100

    private(set) var undoStack: [DocumentState] = []
    private(set) var redoStack: [DocumentState] = []
    private(set) var lastCommitted = DocumentState()
    private(set) var cleanState = DocumentState()

    /// Records `current` as one undo step unless it is the step already
    /// recorded. A new step discards the redo branch.
    mutating func commit(_ current: DocumentState) {
        guard current != lastCommitted else { return }
        undoStack.append(lastCommitted)
        if undoStack.count > Self.stepLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCommitted = current
    }

    /// Steps back when there is a recorded state to return to. The caller
    /// applies the returned value after its own busy guard passes.
    mutating func undo(current: DocumentState) -> DocumentState? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastCommitted = previous
        return previous
    }

    /// Steps forward through a branch recorded by `undo`. The caller only calls
    /// this while `current` still equals `lastCommitted`; an edit in between
    /// invalidates the branch through `commit`.
    mutating func redo(current: DocumentState) -> DocumentState? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastCommitted = next
        return next
    }

    func canUndo(current: DocumentState) -> Bool {
        !undoStack.isEmpty || current != lastCommitted
    }

    func canRedo(current: DocumentState) -> Bool {
        !redoStack.isEmpty && current == lastCommitted
    }

    /// Starts a new document: no steps, and `state` is both the recorded and
    /// the clean baseline.
    mutating func reset(to state: DocumentState) {
        undoStack.removeAll()
        redoStack.removeAll()
        lastCommitted = state
        cleanState = state
    }

    /// Moves the clean baseline without touching history, for save and discard.
    mutating func markClean(_ state: DocumentState) {
        cleanState = state
    }
}
