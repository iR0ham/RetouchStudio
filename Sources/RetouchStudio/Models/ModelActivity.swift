import Foundation

/// The four models the helper can load, named exactly as the worker catalog does.
enum AIModelID: String, CaseIterable {
    case flux = "flux2-klein-4b-q4"
    case sam = "sam2.1-hiera-tiny"
    case swin = "swin2sr-x4"
    case migan = "migan"
}

/// Which model a job is using right now, and when each one last finished a job.
///
/// "In use" means a job is running, not that the weights are resident: the
/// helper loads a model on first use and keeps it until it exits. Jobs call
/// this from worker queues while the manager reads it on the main thread, so
/// every mutation takes the lock and publishes its snapshot to the main queue.
final class ModelActivity: ObservableObject {
    static let shared = ModelActivity()

    @Published private(set) var running: Set<String> = []
    @Published private(set) var lastUsed: [String: Date] = [:]

    private static let lastUsedKey = "ai.model.lastUsed"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var runningIDs: Set<String> = []
    private var used: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Self.lastUsedKey) {
            for (id, value) in stored {
                guard let seconds = value as? Double else { continue }
                used[id] = Date(timeIntervalSince1970: seconds)
            }
        }
        lastUsed = used
    }

    func begin(_ id: AIModelID) {
        lock.lock()
        runningIDs.insert(id.rawValue)
        let snapshot = runningIDs
        lock.unlock()
        publish { $0.running = snapshot }
    }

    /// A job that never reached the worker leaves no last-use behind.
    func finish(_ id: AIModelID, used: Bool) {
        lock.lock()
        runningIDs.remove(id.rawValue)
        if used { self.used[id.rawValue] = Date() }
        let runningSnapshot = runningIDs
        let usedSnapshot = self.used
        defaults.set(usedSnapshot.mapValues { $0.timeIntervalSince1970 },
                     forKey: Self.lastUsedKey)
        lock.unlock()
        publish {
            $0.running = runningSnapshot
            $0.lastUsed = usedSnapshot
        }
    }

    func isRunning(_ rawID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return runningIDs.contains(rawID)
    }

    func lastUse(of rawID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return used[rawID]
    }

    func forget(_ rawID: String) {
        lock.lock()
        runningIDs.remove(rawID)
        used[rawID] = nil
        let runningSnapshot = runningIDs
        let usedSnapshot = used
        defaults.set(usedSnapshot.mapValues { $0.timeIntervalSince1970 },
                     forKey: Self.lastUsedKey)
        lock.unlock()
        publish {
            $0.running = runningSnapshot
            $0.lastUsed = usedSnapshot
        }
    }

    private func publish(_ change: @escaping (ModelActivity) -> Void) {
        if Thread.isMainThread {
            change(self)
        } else {
            DispatchQueue.main.async { change(self) }
        }
    }
}
