import Foundation

/// The out-buffer descriptor from `studioscore_core.h`.
///
/// The layout is two machine words and is checked from C by
/// `Tests/ABI/abi_tests.c`, which allocates this struct itself and reads back
/// what Swift wrote.
@frozen
public struct ScCoreBytes {
    public var ptr: UnsafeMutablePointer<UInt8>?
    public var len: Int
}

enum CoreStatus {
    static let ok: Int32 = 0
    static let invalidArgument: Int32 = 1
    static let invalidJSON: Int32 = 2
    static let projectTooNew: Int32 = 3
    static let unsupportedFeature: Int32 = 4
    static let invalidDocument: Int32 = 5
}

/// `@_cdecl` cannot expose a Swift struct, so every ABI parameter is `void *`
/// and the entry points bind it back to the struct the header declares. The
/// layout is asserted from C by Tests/ABI/abi_tests.c.
@inline(__always)
func coreBytes(_ raw: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<ScCoreBytes>? {
    raw?.assumingMemoryBound(to: ScCoreBytes.self)
}

private struct ErrorPayload: Encodable {
    var code: String
    var message: String
    var detail: String?
}

func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func isJSON(_ data: Data) -> Bool {
    (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
}

func inputData(_ pointer: UnsafePointer<UInt8>?, _ length: Int) -> Data? {
    guard let pointer, length > 0 else { return nil }
    return Data(bytes: pointer, count: length)
}

func stateData(_ pointer: UnsafePointer<UInt8>?, _ length: Int) -> Data? {
    guard let pointer, length >= 0 else { return nil }
    return Data(bytes: pointer, count: length)
}

func clear(_ out: UnsafeMutablePointer<ScCoreBytes>?) {
    guard let out else { return }
    out.pointee.ptr = nil
    out.pointee.len = 0
}

func write(_ out: UnsafeMutablePointer<ScCoreBytes>?, _ data: Data) {
    guard let out else { return }
    out.pointee.ptr = nil
    out.pointee.len = 0
    guard !data.isEmpty else { return }
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
    data.copyBytes(to: buffer, count: data.count)
    out.pointee.ptr = buffer
    out.pointee.len = data.count
}

@discardableResult
func fail(_ status: Int32, _ code: String, _ message: String,
          detail: String? = nil,
          error outError: UnsafeMutablePointer<ScCoreBytes>?) -> Int32 {
    guard let outError else { return status }
    let payload = ErrorPayload(code: code, message: message, detail: detail)
    let data = (try? canonicalJSON(payload))
        ?? Data(#"{"code":"internal","message":"the error could not be encoded"}"#.utf8)
    write(outError, data)
    return status
}
