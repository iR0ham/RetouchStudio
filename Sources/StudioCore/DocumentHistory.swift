import Foundation

/// A document snapshot a history can record. The requirement is only that the
/// value compares by content: the history never looks inside a state, so every
/// document model on every platform can use the same rules. The host supplies
/// the initial state when it creates a history.
public protocol HistoryState: Equatable {}

/// The undo history of one open document: two stacks, the last recorded state
/// and the clean baseline. The rules are identical on every platform, so they
/// live here instead of in a host application.
///
/// The host still owns everything around a step — gesture coalescing, busy
/// guards, status reporting and reloading pixels after a crop or turn. It
/// supplies the current state at each explicit transaction boundary; this type
/// only decides what a boundary does to history.
///
/// It is a value type, so two histories can never share a stack.
public struct DocumentHistory<State: HistoryState> {

    /// A gesture that keeps editing forever must not grow memory without bound.
    public static var stepLimit: Int { 100 }

    public private(set) var undoStack: [State] = []
    public private(set) var redoStack: [State] = []
    public private(set) var lastCommitted: State
    public private(set) var cleanState: State

    public init(_ initial: State) {
        lastCommitted = initial
        cleanState = initial
    }

    /// Records `current` as one undo step unless it is the step already
    /// recorded. A new step discards the redo branch.
    public mutating func commit(_ current: State) {
        guard current != lastCommitted else { return }
        undoStack.append(lastCommitted)
        if undoStack.count > Self.stepLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCommitted = current
    }

    /// Steps back when there is a recorded state to return to. The caller
    /// applies the returned value after its own busy guard passes.
    public mutating func undo(current: State) -> State? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        lastCommitted = previous
        return previous
    }

    /// Steps forward through a branch recorded by `undo`. The caller only calls
    /// this while `current` still equals `lastCommitted`; an edit in between
    /// invalidates the branch through `commit`.
    public mutating func redo(current: State) -> State? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        lastCommitted = next
        return next
    }

    public func canUndo(current: State) -> Bool {
        !undoStack.isEmpty || current != lastCommitted
    }

    public func canRedo(current: State) -> Bool {
        !redoStack.isEmpty && current == lastCommitted
    }

    /// Starts a new document: no steps, and `state` is both the recorded and
    /// the clean baseline.
    public mutating func reset(to state: State) {
        undoStack.removeAll()
        redoStack.removeAll()
        lastCommitted = state
        cleanState = state
    }

    /// Moves the clean baseline without touching history, for save and discard.
    public mutating func markClean(_ state: State) {
        cleanState = state
    }
}
