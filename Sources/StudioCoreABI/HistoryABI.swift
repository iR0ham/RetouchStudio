import Foundation
import StudioCore

/// The byte state a history handle compares. `HistoryState` is a marker
/// protocol, so the ABI declares its own wrapper instead of conforming
/// Foundation's `Data` for every other user of the module.
private struct ABIHistoryState: HistoryState {
    var bytes: Data
}

private final class HistoryBox {
    var history: DocumentHistory<ABIHistoryState>

    init(_ state: Data) {
        history = DocumentHistory(ABIHistoryState(bytes: state))
    }

    func current(_ state: Data) -> ABIHistoryState {
        ABIHistoryState(bytes: state)
    }
}

private func box(_ handle: UnsafeMutableRawPointer?) -> HistoryBox? {
    guard let handle else { return nil }
    return Unmanaged<HistoryBox>.fromOpaque(handle).takeUnretainedValue()
}

@_cdecl("sc_core_abi_version")
public func scCoreABIVersion() -> UInt32 {
    1
}

@_cdecl("sc_core_bytes_release")
public func scCoreBytesRelease(_ raw: UnsafeMutableRawPointer?) {
    guard let bytes = raw?.assumingMemoryBound(to: ScCoreBytes.self) else { return }
    bytes.pointee.ptr?.deallocate()
    bytes.pointee.ptr = nil
    bytes.pointee.len = 0
}

@_cdecl("sc_history_create")
public func scHistoryCreate(_ state: UnsafePointer<UInt8>?, _ stateLength: Int,
                            _ outHistory: UnsafeMutableRawPointer?,
                            _ outError: UnsafeMutableRawPointer?) -> Int32 {
    let outError = coreBytes(outError)
    clear(outError)
    guard let outHistory else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "out_history is required", error: outError)
    }
    let slot = outHistory.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
    slot.pointee = nil
    guard let initial = stateData(state, stateLength) else {
        return fail(CoreStatus.invalidArgument, "invalid_argument",
                    "the initial state is required", error: outError)
    }
    slot.pointee = Unmanaged.passRetained(HistoryBox(initial)).toOpaque()
    return CoreStatus.ok
}

@_cdecl("sc_history_destroy")
public func scHistoryDestroy(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<HistoryBox>.fromOpaque(handle).release()
}

@_cdecl("sc_history_commit")
public func scHistoryCommit(_ handle: UnsafeMutableRawPointer?,
                            _ state: UnsafePointer<UInt8>?,
                            _ stateLength: Int) -> Int32 {
    guard let history = box(handle), let current = stateData(state, stateLength) else {
        return CoreStatus.invalidArgument
    }
    history.history.commit(history.current(current))
    return CoreStatus.ok
}

@_cdecl("sc_history_undo")
public func scHistoryUndo(_ handle: UnsafeMutableRawPointer?,
                          _ current: UnsafePointer<UInt8>?,
                          _ currentLength: Int,
                          _ outState: UnsafeMutableRawPointer?) -> Int32 {
    let outState = coreBytes(outState)
    clear(outState)
    guard let history = box(handle), let currentState = stateData(current, currentLength),
          let outState else {
        return CoreStatus.invalidArgument
    }
    guard let previous = history.history.undo(current: history.current(currentState)) else {
        return CoreStatus.ok
    }
    write(outState, previous.bytes)
    return CoreStatus.ok
}

@_cdecl("sc_history_redo")
public func scHistoryRedo(_ handle: UnsafeMutableRawPointer?,
                          _ current: UnsafePointer<UInt8>?,
                          _ currentLength: Int,
                          _ outState: UnsafeMutableRawPointer?) -> Int32 {
    let outState = coreBytes(outState)
    clear(outState)
    guard let history = box(handle), let currentState = stateData(current, currentLength),
          let outState else {
        return CoreStatus.invalidArgument
    }
    guard let next = history.history.redo(current: history.current(currentState)) else {
        return CoreStatus.ok
    }
    write(outState, next.bytes)
    return CoreStatus.ok
}

@_cdecl("sc_history_flags")
public func scHistoryFlags(_ handle: UnsafeMutableRawPointer?,
                           _ current: UnsafePointer<UInt8>?,
                           _ currentLength: Int,
                           _ outCanUndo: UnsafeMutablePointer<Int32>?,
                           _ outCanRedo: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let history = box(handle), let currentState = stateData(current, currentLength),
          let outCanUndo, let outCanRedo else {
        return CoreStatus.invalidArgument
    }
    let state = history.current(currentState)
    outCanUndo.pointee = history.history.canUndo(current: state) ? 1 : 0
    outCanRedo.pointee = history.history.canRedo(current: state) ? 1 : 0
    return CoreStatus.ok
}

@_cdecl("sc_history_mark_clean")
public func scHistoryMarkClean(_ handle: UnsafeMutableRawPointer?,
                               _ state: UnsafePointer<UInt8>?,
                               _ stateLength: Int) -> Int32 {
    guard let history = box(handle), let clean = stateData(state, stateLength) else {
        return CoreStatus.invalidArgument
    }
    history.history.markClean(history.current(clean))
    return CoreStatus.ok
}

@_cdecl("sc_history_is_dirty")
public func scHistoryIsDirty(_ handle: UnsafeMutableRawPointer?,
                             _ current: UnsafePointer<UInt8>?,
                             _ currentLength: Int,
                             _ outDirty: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let history = box(handle), let currentState = stateData(current, currentLength),
          let outDirty else {
        return CoreStatus.invalidArgument
    }
    outDirty.pointee = history.history.cleanState == history.current(currentState) ? 0 : 1
    return CoreStatus.ok
}
