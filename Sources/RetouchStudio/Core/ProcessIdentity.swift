import Darwin
import Foundation

/// The identity of one running process: PID, kernel start time and canonical
/// executable path.
///
/// A PID alone is a reusable number. Comparing the start time and executable
/// narrows the window in which a recycled PID could be mistaken for the helper,
/// and every signal is preceded by a fresh comparison. This is a mitigation,
/// not a proof: the final `kill` still races with the callback that captured
/// the identity.
struct ProcessIdentity: Codable, Equatable, CustomStringConvertible {
    let pid: Int32
    let startSeconds: Int64
    let startMicroseconds: Int32
    let executable: String

    enum CodingKeys: String, CodingKey {
        case pid
        case startSeconds = "start_seconds"
        case startMicroseconds = "start_microseconds"
        case executable
    }

    var description: String { "pid \(pid) at \(executable)" }

    static func capture(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let copied = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard copied == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return ProcessIdentity(pid: pid,
                               startSeconds: Int64(info.pbi_start_tvsec),
                               startMicroseconds: Int32(info.pbi_start_tvusec),
                               executable: canonical(String(cString: buffer)))
    }

    /// True only if the PID currently names the same process instance with the
    /// same executable. A zombie may still answer here; callers that wait for
    /// exit use their own process handle or a socket probe.
    var isAlive: Bool { ProcessIdentity.capture(pid) == self }

    func isContained(in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return executable == rootPath || executable.hasPrefix(rootPath + "/")
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
