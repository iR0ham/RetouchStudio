import Darwin
import Foundation

// Protocol-v2 lifecycle primitives, exercised across real process boundaries:
//
// G. the helper registry persists a generation/nonce/revision record and a
//    compare-and-swap from another writer cannot overwrite a newer one;
// H. an exclusive usage lease excludes consumers, and process identity (pid +
//    start time + executable) tells a live launcher from a dead one;
// I. a lease duplicated into a grandchild survives the death of the process
//    that spawned it, and is released only when the grandchild exits;
// J. shutdown ownership records accept only the transaction that still owns
//    the stop, and takeover requires a verified-dead owner;
// K. the lock file refuses symlinks and public modes, and a substituted path
//    does not inherit the old holder's lock;
// L. a stale `preparing` record is replaced only while U_EX is held from the
//    probe through the CAS, so no consumer can enter in between.
//
// M starts the real in-repository worker from a fresh support tree and makes
// the host verify its protocol-2 readiness and identity handshake. A stub
// would not prove that the worker source and the host agree. Its
// `capability.list` answer is parsed by the host's own validator too, so the
// frozen vocabulary is proven against what the adapter really writes rather
// than against a payload this file writes.
//
// N asks that same shipped worker to publish a provenance pair and hands it to
// the host's adoption gate. §3.6 is an agreement in two languages, and a
// sidecar this file writes cannot prove the Python half of it.
//
// O sends the job envelope the export really builds through that worker. The
// gate must refuse a named capability before any job exists, and the fields the
// host reads out of `job.status` and `job.result` must be the fields Python
// wrote: a rename on either side leaves every stub-based test green while the
// owner's export fails.

let rawArguments = CommandLine.arguments
if rawArguments.count > 2, rawArguments[1].hasPrefix("--child-") {
    exit(runChild(Array(rawArguments.dropFirst())))
}

unsetenv("RETOUCH_AI_PYTHON")
unsetenv("RETOUCH_AI_WORKER_ROOT")

var failures: [String] = []

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("  ✓ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        print("  ✗ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures.append(label)
    }
}

// AF_UNIX caps a socket path at 104 bytes. The system temporary directory is
// longer than that once the per-test UUID is appended, so keep the tree at the
// short /tmp path instead.
let rootDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
    .appendingPathComponent("rsv2-\(UUID().uuidString.prefix(8))", isDirectory: true)
try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

func freshSupport(_ name: String) -> URL {
    let support = rootDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)",
                                                       isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    return support
}

func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return FileManager.default.fileExists(atPath: url.path)
}

func spawnSelf(_ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

func waitUntilStopped(_ process: Process, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning { return false }
    process.waitUntilExit()
    return true
}

func readMarker(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// A real process that is already dead, with the identity captured while it
/// was alive. This is what a stale launcher or shutdown owner looks like.
func identityOfDeadProcess() -> ProcessIdentity? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["20"]
    guard (try? process.run()) != nil else { return nil }
    let identity = ProcessIdentity.capture(process.processIdentifier)
    process.terminate()
    process.waitUntilExit()
    return identity
}

func spawnLiveSleep() -> (process: Process, identity: ProcessIdentity)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["20"]
    guard (try? process.run()) != nil,
          let identity = ProcessIdentity.capture(process.processIdentifier) else {
        return nil
    }
    return (process, identity)
}

// MARK: - Child processes

func runChild(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 3 else { return 64 }
    let mode = arguments[0]
    let support = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let marker = URL(fileURLWithPath: arguments[2])

    switch mode {
    case "--child-try-shared":
        do {
            let lease = try RuntimeUsageLease.acquireShared(support: support)
            try? Data("ok".utf8).write(to: marker)
            Thread.sleep(forTimeInterval: 0.4)
            lease.release()
            return 0
        } catch {
            try? Data("busy".utf8).write(to: marker)
            return 0
        }

    case "--child-lease-holder":
        // The parent-shaped launch: take the shared lease, hand the descriptor
        // to a grandchild, then release the parent's copy and keep running.
        // A crash of this process must not release the grandchild's lease.
        do {
            let lease = try RuntimeUsageLease.acquireShared(support: support)
            let configuration = RuntimeBootstrap.Configuration(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                environment: [:],
                log: support.appendingPathComponent("holder.log"),
                lease: lease)
            let child = try RuntimeBootstrap.spawn(configuration)
            try? Data("\(child.pid)".utf8).write(to: marker)
            Thread.sleep(forTimeInterval: 60)
            return 0
        } catch {
            try? Data("error: \(error)".utf8).write(to: marker)
            return 70
        }

    case "--child-hold-lock":
        do {
            let lock = try LockFile.open(support.appendingPathComponent("held.lock"))
            try lock.acquire(exclusive: true, timeout: 5, busyMessage: "busy")
            try? Data("held".utf8).write(to: marker)
            Thread.sleep(forTimeInterval: 60)
            lock.close()
            return 0
        } catch {
            return 71
        }

    case "--child-stale-window":
        // The production replacement order, with a deterministic pause between
        // the registry probe and the CAS: U_EX is held across both.
        do {
            let window = arguments.count > 3 ? (Double(arguments[3]) ?? 1.0) : 1.0
            let lease = try RuntimeUsageLease.acquireExclusive(support: support,
                                                               timeout: 10)
            defer { lease.release() }
            let store = try HelperRegistryStore(root: support)
            var probed: HelperRegistry.Record?
            if case .loaded(let record) = store.read() { probed = record }
            try? Data((probed?.launchNonce ?? "none").utf8).write(
                to: marker.appendingPathExtension("probed"))
            Thread.sleep(forTimeInterval: window)
            guard let stale = probed,
                  let identity = ProcessIdentity.capture(getpid()) else {
                return 74
            }
            var replaced = false
            try store.update { load in
                guard case .loaded(let current) = load,
                      current.generation == stale.generation,
                      current.launchNonce == stale.launchNonce,
                      current.state == .preparing else { return (nil, ()) }
                let fresh = RuntimeBootstrap.preparingRecord(
                    parent: identity,
                    socket: support.appendingPathComponent("worker.sock"),
                    previous: current)
                replaced = true
                return (fresh, ())
            }
            try? Data((replaced ? "replaced" : "stale").utf8).write(
                to: marker.appendingPathExtension("replaced"))
            // Keep U_EX until the parent has observed the exclusion and the
            // replaced record; a fixed sleep could release too early.
            let release = support.appendingPathComponent("stale-window-release")
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: release.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            return replaced ? 0 : 75
        } catch {
            try? Data("error: \(error)".utf8).write(
                to: marker.appendingPathExtension("replaced"))
            return 76
        }

    default:
        return 64
    }
}

// MARK: - G

func testRegistryRecordAndCAS() {
    print("\n[G] the registry keeps generation, nonce and revision honest")
    let support = freshSupport("registry")
    let store: HelperRegistryStore
    do {
        store = try HelperRegistryStore(root: support)
    } catch {
        check(false, "G: the registry store opens", "\(error)")
        return
    }
    guard let parent = ProcessIdentity.capture(getpid()) else {
        check(false, "G: this process has an identity")
        return
    }
    let socket = support.appendingPathComponent("worker.sock")
    let preparing = RuntimeBootstrap.preparingRecord(parent: parent, socket: socket,
                                                     previous: nil)
    check(UUID(uuidString: preparing.generation) != nil
            && UUID(uuidString: preparing.launchNonce) != nil
            && preparing.generation != preparing.launchNonce,
          "G: generation and launch nonce are distinct identifiers")
    check(preparing.revision == 1, "G: the first record starts at revision 1")

    do {
        try store.update { _ in (preparing, ()) }
    } catch {
        check(false, "G: the preparing record is written", "\(error)")
        return
    }
    if case .loaded(let read) = store.read() {
        check(read == preparing, "G: the record round-trips unchanged")
    } else {
        check(false, "G: the written record reads back")
    }

    let now = Date()
    var ready: HelperRegistry.Record?
    try? store.update { load -> (HelperRegistry.Record?, Void) in
        guard case .loaded(var current) = load,
              current.generation == preparing.generation,
              current.launchNonce == preparing.launchNonce,
              current.state == .preparing else {
            return (nil, ())
        }
        current.state = .ready
        current.helper = parent
        let next = current.bumped(at: now)
        ready = next
        return (next, ())
    }
    check(ready?.revision == 2 && ready?.state == .ready,
          "G: a matching CAS moves preparing to ready and bumps revision")

    var staleWrote = false
    _ = try? store.update { load in
        guard case .loaded(var current) = load,
              current.generation == preparing.generation,
              current.launchNonce == "a stale launch" else {
            return (nil, ())
        }
        staleWrote = true
        return (current.bumped(at: now), ())
    }
    check(!staleWrote, "G: a stale nonce cannot write the registry")
    if case .loaded(let after) = store.read() {
        check(after.revision == 2 && after.state == .ready,
              "G: the stale writer left revision and state unchanged")
    } else {
        check(false, "G: the registry still reads after a stale write")
    }

    var bad = preparing
    bad.helper = parent
    check((try? bad.validated()) == nil,
          "G: a preparing record naming a helper is rejected")

    let manager = FileManager.default
    let registry = support.appendingPathComponent(HelperRegistry.fileName)
    if let data = try? Data(contentsOf: registry),
       var extra = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        extra["unexpected"] = true
        if let changed = try? JSONSerialization.data(withJSONObject: extra) {
            try? changed.write(to: registry)
        }
        check(registryIsInvalid(registry), "G: an unexpected registry field is rejected")
    } else {
        check(false, "G: the registry could be read for the key check")
    }

    try? Data("{}".utf8).write(to: registry)
    try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: registry.path)
    check(registryIsInvalid(registry), "G: a public registry file is rejected")
    try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registry.path)

    let target = support.appendingPathComponent("registry-target.json")
    try? Data("{}".utf8).write(to: target)
    try? manager.removeItem(at: registry)
    try? manager.createSymbolicLink(at: registry, withDestinationURL: target)
    check(registryIsInvalid(registry), "G: a symlinked registry is rejected")
}

func registryIsInvalid(_ url: URL) -> Bool {
    if case .invalid = HelperRegistry.read(from: url) { return true }
    return false
}

// MARK: - H

func testExclusiveLeaseExcludesConsumers() {
    print("\n[H] the exclusive lease excludes every consumer")
    let support = freshSupport("exclusive")
    let exclusive: RuntimeUsageLease
    do {
        exclusive = try RuntimeUsageLease.acquireExclusive(support: support, timeout: 0)
    } catch {
        check(false, "H: the exclusive lease is taken", "\(error)")
        return
    }

    let busyMarker = support.appendingPathComponent("shared-busy")
    do {
        let child = try spawnSelf(["--child-try-shared", support.path, busyMarker.path])
        defer { _ = waitUntilStopped(child, timeout: 5) }
        check(waitForFile(busyMarker, timeout: 5), "H: the consumer process ran")
        check(readMarker(busyMarker) == "busy",
              "H: a consumer cannot take a shared lease while the installer holds it")
    } catch {
        check(false, "H: the consumer process starts", "\(error)")
    }

    exclusive.release()
    let freeMarker = support.appendingPathComponent("shared-free")
    do {
        let child = try spawnSelf(["--child-try-shared", support.path, freeMarker.path])
        defer { _ = waitUntilStopped(child, timeout: 5) }
        check(waitForFile(freeMarker, timeout: 5), "H: the second consumer process ran")
        check(readMarker(freeMarker) == "ok",
              "H: the shared lease is available after the installer releases it")
    } catch {
        check(false, "H: the second consumer starts", "\(error)")
    }
}

func testIdentityDistinguishesLiveness() {
    print("\n[H] process identity separates a live launcher from a dead one")
    guard let dead = identityOfDeadProcess() else {
        check(false, "H: a dead process identity was captured")
        return
    }
    check(!dead.isAlive,
          "H: a captured identity is dead after the process exits",
          "pid \(dead.pid)")
    guard let live = spawnLiveSleep() else {
        check(false, "H: a live process was started")
        return
    }
    defer {
        live.process.terminate()
        _ = waitUntilStopped(live.process, timeout: 3)
    }
    check(live.identity.isAlive, "H: the same identity is alive while the process runs")
    check(!dead.isAlive && live.identity.isAlive,
          "H: liveness is decided by pid, start time and executable together")
    check(live.identity.isContained(in: URL(fileURLWithPath: "/bin")),
          "H: containment is answered against the canonical executable")

    guard let current = ProcessIdentity.capture(getpid()),
          let encoded = try? JSONEncoder().encode(current),
          let decoded = try? JSONDecoder().decode(ProcessIdentity.self, from: encoded) else {
        check(false, "H: an identity survives its wire encoding")
        return
    }
    check(decoded == current, "H: an identity survives its wire encoding")
}

// MARK: - I

func testChildOwnedLeaseSurvivesParentDeath() {
    print("\n[I] a child-owned lease survives the parent process")
    let support = freshSupport("child-lease")
    let marker = support.appendingPathComponent("holder-ready")
    let parent: Process
    do {
        parent = try spawnSelf(["--child-lease-holder", support.path, marker.path])
    } catch {
        check(false, "I: the launching process starts", "\(error)")
        return
    }
    guard waitForFile(marker, timeout: 10),
          let text = readMarker(marker), let grandchildPID = Int32(text),
          grandchildPID > 0 else {
        check(false, "I: the grandchild started", readMarker(marker) ?? "no marker")
        parent.terminate()
        _ = waitUntilStopped(parent, timeout: 3)
        return
    }
    defer {
        if kill(grandchildPID, 0) == 0 { kill(grandchildPID, SIGKILL) }
    }
    check(kill(grandchildPID, 0) == 0, "I: the grandchild is running",
          "pid \(grandchildPID)")

    // While the grandchild lives, an installer cannot take the exclusive lease
    // even though the launching process is about to disappear.
    var busyWhileParentAlive = false
    do {
        _ = try RuntimeUsageLease.acquireExclusive(support: support, timeout: 0.3)
    } catch {
        busyWhileParentAlive = true
    }
    check(busyWhileParentAlive,
          "I: the inherited lease blocks an installer before the parent dies")

    kill(parent.processIdentifier, SIGKILL)
    check(waitUntilStopped(parent, timeout: 5), "I: the launching process is killed",
          "pid \(parent.processIdentifier)")
    Thread.sleep(forTimeInterval: 0.3)
    check(kill(grandchildPID, 0) == 0,
          "I: the grandchild outlives the process that spawned it")
    var busyAfterCrash = false
    do {
        _ = try RuntimeUsageLease.acquireExclusive(support: support, timeout: 0.3)
    } catch {
        busyAfterCrash = true
    }
    check(busyAfterCrash,
          "I: the lease survives the launcher's crash through the child descriptor")

    kill(grandchildPID, SIGTERM)
    let deadline = Date().addingTimeInterval(5)
    var acquired = false
    while Date() < deadline && !acquired {
        if let lease = try? RuntimeUsageLease.acquireExclusive(support: support,
                                                               timeout: 0.2) {
            lease.release()
            acquired = true
        }
    }
    check(acquired, "I: the exclusive lease is released when the grandchild exits")
}

// MARK: - J

func testShutdownOwnershipCAS() {
    print("\n[J] shutdown ownership accepts only the owning transaction")
    let support = freshSupport("shutdown")
    let store: HelperRegistryStore
    do {
        store = try HelperRegistryStore(root: support)
    } catch {
        check(false, "J: the registry store opens", "\(error)")
        return
    }
    guard let owner = ProcessIdentity.capture(getpid()),
          let helper = spawnLiveSleep() else {
        check(false, "J: identities for the record are available")
        return
    }
    defer {
        helper.process.terminate()
        _ = waitUntilStopped(helper.process, timeout: 3)
    }

    let now = Date()
    var record = RuntimeBootstrap.preparingRecord(
        parent: owner, socket: support.appendingPathComponent("worker.sock"), previous: nil)
    record.state = .ready
    record.helper = helper.identity
    record.clients = [HelperRegistry.Client(id: UUID().uuidString, identity: owner,
                                            lastSeen: now.timeIntervalSince1970)]
    let shutdown = HelperRegistry.Shutdown(
        transactionID: UUID().uuidString, owner: owner,
        startedAt: now.timeIntervalSince1970, revisionAtStart: record.revision,
        generation: record.generation)
    var stopping = record.bumped(at: now)
    stopping.state = .stopping
    stopping.shutdown = shutdown
    do {
        try store.update { _ in (stopping, ()) }
    } catch {
        check(false, "J: the stopping record is written", "\(error)")
        return
    }
    check((try? stopping.validated()) != nil, "J: a consistent stopping record validates")

    let before = store.read()
    var staleFinalized = false
    _ = try? store.update { load in
        guard case .loaded(var current) = load,
              current.generation == stopping.generation,
              current.state == .stopping,
              current.shutdown?.transactionID == "another shutdown" else {
            return (nil, ())
        }
        staleFinalized = true
        current.state = .stopped
        return (current.bumped(at: now), ())
    }
    check(!staleFinalized, "J: a stale performer cannot finalize the stop")
    var beforeRevision = -1
    if case .loaded(let old) = before { beforeRevision = old.revision }
    if case .loaded(let after) = store.read() {
        check(after.revision == beforeRevision && after.state == .stopping,
              "J: the record is unchanged by the stale performer")
    } else {
        check(false, "J: the registry still reads")
    }

    let deadOwner = identityOfDeadProcess()
    check(deadOwner?.isAlive == false,
          "J: a takeover candidate must prove the previous owner is dead")
    var mismatchedGeneration = stopping
    mismatchedGeneration.shutdown = HelperRegistry.Shutdown(
        transactionID: UUID().uuidString, owner: owner,
        startedAt: now.timeIntervalSince1970, revisionAtStart: 1,
        generation: UUID().uuidString)
    check((try? mismatchedGeneration.validated()) == nil,
          "J: a stop naming another helper generation is rejected")
}

// MARK: - K

func testLockFileHardening() {
    print("\n[K] lock files refuse substitutes and conflicting holders")
    let support = freshSupport("locks")
    let manager = FileManager.default
    let target = support.appendingPathComponent("target.lock")

    let symlink = support.appendingPathComponent("symlink.lock")
    try? Data().write(to: target)
    try? manager.createSymbolicLink(at: symlink, withDestinationURL: target)
    var symlinkRejected = false
    do { _ = try LockFile.open(symlink) } catch { symlinkRejected = true }
    check(symlinkRejected, "K: a symlinked lock file is refused")

    let publicLock = support.appendingPathComponent("public.lock")
    try? Data().write(to: publicLock)
    try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicLock.path)
    var publicRejected = false
    do { _ = try LockFile.open(publicLock) } catch { publicRejected = true }
    check(publicRejected, "K: a lock file other users can read is refused")

    let marker = support.appendingPathComponent("lock-held")
    let child: Process
    do {
        child = try spawnSelf(["--child-hold-lock", support.path, marker.path])
    } catch {
        check(false, "K: the lock holder starts", "\(error)")
        return
    }
    guard waitForFile(marker, timeout: 5) else {
        check(false, "K: the lock holder took the lock")
        child.terminate()
        _ = waitUntilStopped(child, timeout: 3)
        return
    }

    let heldPath = support.appendingPathComponent("held.lock")
    // Keep this handle to the exact inode the child locked: the substitution
    // below unlinks the path, so this is the only way back to that resource.
    let held = try? LockFile.open(heldPath)
    let blocked = held.map { !$0.tryAcquire(exclusive: true) } ?? false
    check(blocked, "K: a second process cannot take the lock")

    // The lock protects the inode, not the path. Replacing the path is
    // detected at open time and never silently treated as the held lock.
    let oldInode: ino_t? = {
        var info = stat()
        guard lstat(heldPath.path, &info) == 0 else { return nil }
        return info.st_ino
    }()
    try? manager.removeItem(at: heldPath)
    try? Data().write(to: heldPath)
    // `Data.write` creates 0644; the lock rejects a path it did not create
    // with private permissions, so set the mode before reopening.
    try? manager.setAttributes([.posixPermissions: 0o600],
                               ofItemAtPath: heldPath.path)
    let replacement = try? LockFile.open(heldPath)
    let newInode = replacement?.inode
    check(oldInode != nil && newInode != nil && oldInode != newInode,
          "K: a substituted lock path names a different inode than the holder")
    let replacementAcquired = replacement?.tryAcquire(exclusive: true) ?? false
    check(replacementAcquired,
          "K: the substituted path is a different, unlocked inode")
    replacement?.close()

    kill(child.processIdentifier, SIGKILL)
    check(waitUntilStopped(child, timeout: 5), "K: the lock holder is killed")
    // The child's flock lives in the kernel until its descriptor owner dies.
    // Reacquire through the handle to the same inode, not the replaced path.
    let released = held?.tryAcquire(exclusive: true) ?? false
    check(released, "K: a crashed holder releases the exact lock resource")
    held?.close()
}

// MARK: - L

func testStalePreparingReplacementHoldsExclusiveLease() {
    print("\n[L] a stale launch record is replaced only under a continuous U_EX")
    let support = freshSupport("stale-window")
    guard let deadParent = identityOfDeadProcess() else {
        check(false, "L: a dead launcher identity was captured")
        return
    }
    let store: HelperRegistryStore
    do {
        store = try HelperRegistryStore(root: support)
    } catch {
        check(false, "L: the registry opens", "\(error)")
        return
    }
    let socket = support.appendingPathComponent("worker.sock")
    let stale = RuntimeBootstrap.preparingRecord(parent: deadParent, socket: socket,
                                                 previous: nil)
    do {
        try store.update { _ in (stale, ()) }
    } catch {
        check(false, "L: the stale record is written", "\(error)")
        return
    }
    check(!deadParent.isAlive, "L: the recorded launcher is verifiably dead")

    let base = support.appendingPathComponent("race")
    let child: Process
    do {
        child = try spawnSelf(["--child-stale-window", support.path, base.path, "1.0"])
    } catch {
        check(false, "L: the replacing process starts", "\(error)")
        return
    }
    guard waitForFile(base.appendingPathExtension("probed"), timeout: 5) else {
        check(false, "L: the replacing process probed the stale record under U_EX")
        child.terminate()
        _ = waitUntilStopped(child, timeout: 3)
        return
    }

    // The probe has happened and the CAS has not: a consumer must still see
    // the exclusive lease, and a second replacer must not enter either.
    var consumerBlocked = false
    do { _ = try RuntimeUsageLease.acquireShared(support: support) }
    catch is AIRuntimeBusyError { consumerBlocked = true }
    catch {}
    check(consumerBlocked, "L: a consumer cannot enter between the probe and the CAS")
    var secondInstallerBlocked = false
    do {
        _ = try RuntimeUsageLease.acquireExclusive(support: support, timeout: 0.3)
    } catch is AIRuntimeBusyError { secondInstallerBlocked = true }
    catch {}
    check(secondInstallerBlocked,
          "L: a second replacement cannot enter between the probe and the CAS")
    if case .loaded(let before) = store.read() {
        check(before.launchNonce == stale.launchNonce,
              "L: the stale record is untouched while the probe is in flight")
    } else {
        check(false, "L: the stale record is still readable")
    }

    check(waitForFile(base.appendingPathExtension("replaced"), timeout: 5),
          "L: the replacing process CASed the stale record")
    var postCASBlocked = false
    do { _ = try RuntimeUsageLease.acquireShared(support: support) }
    catch is AIRuntimeBusyError { postCASBlocked = true }
    catch {}
    check(postCASBlocked, "L: the consumer is still excluded after the CAS")
    if case .loaded(let after) = store.read() {
        check(after.launchNonce != stale.launchNonce && after.state == .preparing,
              "L: the replaced record carries a fresh launch nonce")
    } else {
        check(false, "L: the replaced record reads back")
    }

    try? Data().write(to: support.appendingPathComponent("stale-window-release"))
    check(waitUntilStopped(child, timeout: 5), "L: the replacing process exits")
    let free = try? RuntimeUsageLease.acquireShared(support: support)
    check(free != nil, "L: the exclusive lease is released only after the CAS")
    free?.release()
}

// MARK: - A live helper

/// Why there is no live worker to start, phrased as the check that reports it.
enum LiveWorkerProblem: String {
    case noInterpreter = "a worker interpreter is available"
    case noSource = "the worker source is in this checkout"
}

let liveWorkerRemedy
    = "set RETOUCH_WORKER_PYTHON or create worker/.venv with Tools/setup-worker-venv.sh"

/// Where the shipped worker lives and which interpreter runs it. Every section
/// that needs a real worker rather than a stub resolves it the same way, with
/// the checkout's `worker/.venv` as the fallback.
func liveWorker() -> Result<(repo: URL, worker: URL, python: URL), LiveWorkerProblem> {
    let environment = ProcessInfo.processInfo.environment
    let repo = URL(fileURLWithPath: environment["RETOUCH_TESTS_ROOT"]
                   ?? FileManager.default.currentDirectoryPath, isDirectory: true)
    let worker = repo.appendingPathComponent("worker", isDirectory: true)
    let python = environment["RETOUCH_WORKER_PYTHON"].map { URL(fileURLWithPath: $0) }
        ?? worker.appendingPathComponent(".venv/bin/python3")
    guard FileManager.default.isExecutableFile(atPath: python.path) else {
        return .failure(.noInterpreter)
    }
    guard FileManager.default.fileExists(
        atPath: worker.appendingPathComponent("retouch_ai_worker").path) else {
        return .failure(.noSource)
    }
    return .success((repo, worker, python))
}

struct LiveHelperError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A real helper running from a support tree of its own, with the roots it was
/// told it may read.
struct LiveHelper {
    let support: URL
    let inputs: URL
    let jobs: URL
    let models: URL
    let socket: URL
    let log: URL
    let ready: HelperRegistry.Record?
    let client: WorkerClient
    let child: ChildProcess
    private let lease: RuntimeUsageLease

    /// A refusal is only useful if the helper's own log explains it, so a failing
    /// run prints the tail rather than an exit code.
    var logTail: String {
        String(((try? String(contentsOf: log, encoding: .utf8)) ?? "").suffix(400))
    }

    /// For a section that ends without shutting the helper down itself. A test
    /// run must never outlive the worker it started: the child owns the shared
    /// usage lease, so an orphan keeps it until it exits on its own and slows
    /// the exclusive-lease checks in another suite. `terminate` is only SIGTERM,
    /// so a helper that ignores both the protocol and the signal is killed.
    func stopIfNeeded() {
        guard child.isRunning else { return }
        _ = try? WorkerClient(socketPath: socket.path).call("shutdown", timeout: 5)
        if child.wait(timeout: 5) { return }
        child.terminate()
        if child.wait(timeout: 5) { return }
        child.send(SIGKILL)
        _ = child.wait(timeout: 5)
    }
}

/// Starts the shipped worker the way the app starts one — a preparing record, a
/// shared usage lease held across the spawn, then the same arguments — and waits
/// for the registry to call that launch ready. A nil `ready` is the failure, and
/// `logTail` is its reason.
func launchLiveHelper(worker: URL, python: URL, named name: String) throws -> LiveHelper {
    let support = freshSupport(name)
    let inputs = support.appendingPathComponent("inputs")
    let jobs = support.appendingPathComponent("jobs")
    let models = support.appendingPathComponent("models")
    let socket = support.appendingPathComponent("worker.sock")
    let log = support.appendingPathComponent("worker.log")
    for folder in [inputs, jobs, models] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    guard let parent = ProcessIdentity.capture(getpid()) else {
        throw LiveHelperError(message: "this process has no identity")
    }
    let store = try HelperRegistryStore(root: support)
    let preparing = RuntimeBootstrap.preparingRecord(parent: parent, socket: socket,
                                                     previous: nil)
    try store.update { _ in (preparing, ()) }
    let lease = try RuntimeUsageLease.acquireShared(support: support)
    let arguments = RuntimeBootstrap.arguments(
        socket: socket, jobs: jobs, models: models, allowRoots: [inputs, jobs, models],
        generation: preparing.generation, nonce: preparing.launchNonce,
        registry: support.appendingPathComponent(HelperRegistry.fileName))
    let environment = ProcessInfo.processInfo.environment
    var childEnvironment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": environment["HOME"] ?? NSHomeDirectory(),
        "TMPDIR": NSTemporaryDirectory(),
        "PYTHONPATH": worker.path,
        "PYTHONUNBUFFERED": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    ]
    if let lang = environment["LANG"] { childEnvironment["LANG"] = lang }
    let child = try RuntimeBootstrap.spawn(RuntimeBootstrap.Configuration(
        executable: python, arguments: arguments,
        environment: childEnvironment, log: log, lease: lease))
    let ready = RuntimeBootstrap.waitForReady(store: store, generation: preparing.generation,
                                              nonce: preparing.launchNonce, timeout: 30)
    return LiveHelper(support: support, inputs: inputs, jobs: jobs, models: models,
                      socket: socket, log: log, ready: ready,
                      client: WorkerClient(socketPath: socket.path),
                      child: child, lease: lease)
}

/// One decodable PNG inside a root the helper was told it may open. No job
/// below looks at these bytes; the envelope that carries them is what is under
/// test, so it is the smallest real image rather than a made-up path.
func writeLivePixel(_ directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("pixel.png")
    guard let data = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """) else {
        throw LiveHelperError(message: "the pixel fixture is not valid base64")
    }
    try data.write(to: url)
    return url
}

// MARK: - M

/// A real helper process, started the way the app starts one, answering the
/// protocol-2 handshake the host enforces. A stub or an in-process fake would
/// not prove that the shipped worker source and the host agree.
func testRealHelperHandshake() {
    print("\n[M] a real helper process completes the protocol-2 handshake")
    let worker: (repo: URL, worker: URL, python: URL)
    switch liveWorker() {
    case .failure(let problem):
        check(false, "M: \(problem.rawValue)", liveWorkerRemedy)
        return
    case .success(let found):
        worker = found
    }
    let live: LiveHelper
    do {
        live = try launchLiveHelper(worker: worker.worker, python: worker.python,
                                    named: "protocol2")
    } catch {
        check(false, "M: the real helper starts", "\(error)")
        return
    }
    defer { live.stopIfNeeded() }
    guard let ready = live.ready else {
        check(false, "M: the helper publishes a ready registry record", live.logTail)
        return
    }
    let root = worker.repo
    let socket = live.socket
    let log = live.log
    let child = live.child
    let client = live.client
    do {
        check(ready.state == .ready && ready.helper?.pid == child.pid,
              "M: the helper publishes a ready registry record naming its process")
        guard let helper = ready.helper else {
            check(false, "M: the ready record carries the helper identity")
            return
        }
        let health: [String: Any]
        do {
            health = try client.verifiedHealth(generation: ready.generation,
                                               nonce: ready.launchNonce,
                                               helper: helper)
        } catch {
            check(false, "M: the host verifies the helper's identity", "\(error)")
            return
        }
        check(health["protocol_version"] as? Int == 2,
              "M: health reports protocol_version 2")
        check(health["contractVersion"] as? String == "1",
              "M: health carries the shared contract version")
        check(health["helper_generation"] as? String == ready.generation,
              "M: health echoes the generation")
        check(health["launch_nonce"] as? String == ready.launchNonce,
              "M: health echoes the launch nonce")
        // Nothing has loaded a model at this point, so a provider would be a
        // claim about a runtime that never initialised.
        let provider = (health["providers"] as? [[String: Any]])?.first
        check(provider?["execution_providers"] as? [String] == [],
              "M: health names no execution provider before a model has loaded")
        check(provider?["state"] as? String == "unavailable"
                && (provider?["reason"] as? String)?.isEmpty == false,
              "M: an uninitialised provider says why")

        // The same field set both platforms must answer, read from the shared
        // fixture rather than repeated here.
        let fixture = root.appendingPathComponent("Tests/Contract/protocol2.json")
        if let data = try? Data(contentsOf: fixture),
           let contract = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let expected = (contract["health"] as? [String: Any])?["result"]
                as? [String: Any] {
            check(expected.keys.allSatisfy { health[$0] != nil },
                  "M: health replies with every field the shared fixture requires")
            if let methods = contract["requiredMethods"] as? [String] {
                let answered = Set(["hello", "health", "ping", "provider.list", "shutdown"])
                check(methods.allSatisfy { answered.contains($0) },
                      "M: the host answers every method the shared fixture requires")
            } else {
                check(false, "M: the shared fixture lists required methods")
            }
        } else {
            check(false, "M: the shared protocol fixture is readable")
        }

        let hello = (try? client.call("hello")) as? [String: Any] ?? [:]
        check(hello["protocol_version"] as? Int == 2,
              "M: hello reports protocol_version 2")
        let providers = (try? client.call("provider.list")) as? [String: Any]
        check(providers?["contractVersion"] as? String == "1",
              "M: provider.list carries the shared contract version")
        check((providers?["providers"] as? [[String: Any]])?.isEmpty == false,
              "M: provider.list returns a provider record")
        // The shared fixture types a provider record; both platforms must
        // emit that shape, and both carry the unavailable explanation as
        // `reason` (the Windows adapter was aligned to this in W5-5).
        if let data = try? Data(contentsOf: root.appendingPathComponent(
                "Tests/Contract/protocol2.json")),
            let contract = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any],
            let providerType = contract["provider"] as? [String: Any],
            providerType["state"] != nil {
            let record = (providers?["providers"] as? [[String: Any]])?.first
            check(record?["id"] is String
                    && ["available", "unavailable"]
                        .contains(record?["state"] as? String ?? "")
                    && record?["execution_providers"] != nil,
                  "M: the provider record matches the shared fixture type")
        }
        let pong = (try? client.call("ping")) as? [String: Any]
        check(pong?["pong"] as? Bool == true,
              "M: ping answers pong")

        // What the adapter actually answers, run through the host's own
        // validator. W5-3 proves the validator against payloads written here;
        // only a live worker can prove the two sides still spell the frozen
        // vocabulary the same way. Nothing is loaded to answer it, so this
        // stays cheap and cannot disturb a job.
        let capabilityReply = try? client.call("capability.list", timeout: 15)
        if let payload = capabilityReply as? [String: Any],
           let report = AICapabilityReport(payload: payload) {
            check(true, "M: the live worker's capability report decodes in the host")
            check(report.capabilities.count == AICapabilityReport.vocabularyIds.count
                    && Set(report.capabilities.map(\.id))
                        == Set(AICapabilityReport.vocabularyIds),
                  "M: the adapter answers every frozen id exactly once")
            check(["macos-arm64", "macos-x64"].contains(report.platform),
                  "M: the report names a platform the host recognises", report.platform)
            check(report.provider == "macos-python",
                  "M: the report names the adapter", report.provider)
            // The rule that keeps a report honest, checked against real output
            // rather than a fixture: a claim of support carries the run that
            // justifies it, and any other state says why.
            check(report.capabilities.allSatisfy { capability in
                capability.state == .supported
                    ? (capability.evidence?.isEmpty == false)
                    : (capability.reason?.isEmpty == false)
            }, "M: every live record backs its state with evidence or a reason")
        } else {
            check(false, "M: the live worker's capability report decodes in the host",
                  String(describing: capabilityReply).prefix(200).description)
        }

        _ = try? client.call("shutdown", timeout: 5)
        check(child.wait(timeout: 10), "M: the helper exits after shutdown")
        let deadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: socket.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        check(!FileManager.default.fileExists(atPath: socket.path),
              "M: shutdown removes the socket")
    }
}

// MARK: - N

/// §3.6 leaves adoption to one comparison made in two languages: the shipped
/// worker records a digest beside the artifact it renames into place, and the
/// host re-hashes those bytes before it will show them. The host's own checks
/// have Swift write both halves of that pair, so they test the validator and
/// never the agreement. This section runs the real `provenance` module over a
/// real PNG, in the shape `engine._job_upscale` publishes, and hands the paths
/// back to `AIProvenance.verifiedArtifact`. No weights load and no inference
/// runs: the pixels are not under test, the publication is.
func testWorkerPublishedPairIsAdoptedByHost() {
    print("\n[N] the host adopts a pair the shipped worker published")
    guard case .success(let worker) = liveWorker() else {
        check(false, "N: \(liveWorkerRemedy)")
        return
    }
    let root = worker.repo
    let workerRoot = worker.worker
    let python = worker.python

    let folder = freshSupport("pair")
    let script = """
    import json, sys
    sys.path.insert(0, sys.argv[1])
    from pathlib import Path

    import numpy as np
    from PIL import Image

    from retouch_ai_worker import provenance
    from retouch_ai_worker.capabilities import current_platform
    from retouch_ai_worker.protocol import CONTRACT_VERSION

    folder = Path(sys.argv[2])
    staged, target = folder / "upscaled.png.tmp", folder / "upscaled.png"
    source = np.zeros((2, 2, 3), dtype=np.uint8)
    source[0, 0] = (200, 30, 30)
    Image.fromarray(source).save(staged, format="PNG")
    record = provenance.document(
        capability_id="upscale.2x", job_id="host-adoption",
        contract_version=CONTRACT_VERSION,
        model={"name": "fixture", "version": None, "digest": None},
        adapter={"platform": current_platform(), "version": "0.1.0"},
        parameters={"scale": 2, "tile": 512, "overlap": 32}, seed=None,
        input=provenance.pixels(source), output=provenance.artifact(staged),
        authorized_rect={"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
        outside_pixels_identical=None, elapsed_seconds=0.0, state="succeeded")
    sidecar = provenance.publish(staged, target, record)
    print(json.dumps({"artifact": str(target), "sidecar": str(sidecar),
                      "record": json.loads(sidecar.read_text("utf-8"))}), flush=True)
    """
    let process = Process()
    process.executableURL = python
    process.arguments = ["-c", script, workerRoot.path, folder.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        check(false, "N: the worker's provenance module runs", "\(error)")
        return
    }
    let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: bytes, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0,
          let line = output.split(separator: "\n").first(where: { $0.hasPrefix("{") }),
          let reply = (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
            as? [String: Any],
          let artifactPath = reply["artifact"] as? String,
          let sidecarPath = reply["sidecar"] as? String else {
        check(false, "N: the worker publishes a pair", String(output.suffix(500)))
        return
    }
    let artifact = URL(fileURLWithPath: artifactPath)
    let sidecar = URL(fileURLWithPath: sidecarPath)
    let record = (reply["record"] as? [String: Any]) ?? [:]

    var adopted: URL?
    var refusal: String = ""
    do {
        adopted = try AIProvenance.verifiedArtifact(path: artifactPath,
                                                    sidecarPath: sidecarPath)
    } catch {
        refusal = "\(error)"
    }
    check(adopted == artifact, "N: the host adopts what the worker published", refusal)

    let recorded = ((record["output"] as? [String: Any])?["sha256"] as? String) ?? ""
    let hashed = (try? AIRuntime.sha256(of: artifact)) ?? ""
    check(hashed.count == 64 && hashed == recorded,
          "N: both languages hash these bytes to the same digest",
          "host \(hashed.prefix(12)) worker \(recorded.prefix(12))")

    check(record["schema"] as? String == AIProvenance.schema,
          "N: the worker writes the schema string the host requires")
    check(sidecar.lastPathComponent == artifact.lastPathComponent
                    + AIProvenance.sidecarSuffix
            && sidecar.deletingLastPathComponent().path
                == artifact.deletingLastPathComponent().path,
          "N: the sidecar is where the host looks for it")

    let required: Set<String> = ["schema", "contractVersion", "capabilityId", "jobId",
                                 "createdAt", "model", "adapter", "parameters", "seed",
                                 "input", "output", "authorizedRect",
                                 "outsidePixelsIdentical", "elapsedSeconds", "state"]
    let missing = required.subtracting(record.keys).sorted()
    check(missing.isEmpty, "N: the record carries every §3.6 field",
          missing.joined(separator: " "))

    if let original = try? Data(contentsOf: artifact) {
        var tampered = original
        tampered.append(0x00)
        try? tampered.write(to: artifact)
        check((try? AIProvenance.verifiedArtifact(path: artifactPath,
                                                  sidecarPath: sidecarPath)) == nil,
              "N: a byte the record does not name makes the host refuse the pair")
    } else {
        check(false, "N: the artifact is readable")
    }
}

// MARK: - O

/// `job.submit` is the call the owner's export cannot survive without, and its
/// envelope, its refusal and its reply are named in two languages. The worker's
/// own suite already sends these frames over a socket and checks the codes back
/// (`worker/tests/test_server.py`), so the gate is proven in Python. What was
/// never proven is the Swift reader: `WorkerClient.submit`, `wait` and
/// `AIWorkerFailure.typedCode` had no test that reached a real helper at all,
/// and the stubs the other suites use answer with fields those same files
/// wrote. A rename on the Python side would therefore leave every Swift test
/// green while the owner's export stopped working. This section sends the
/// envelope `ExportService` really builds — `upscale`, `{"image": {"path": …}}`
/// — through a live helper whose models root holds nothing, which makes the
/// answers the frozen table's rather than this machine's luck.
func testHostJobSubmissionAgainstLiveWorker() {
    print("\n[O] the host and the worker agree on the job fields")
    guard case .success(let worker) = liveWorker() else {
        check(false, "O: \(liveWorkerRemedy)")
        return
    }
    let live: LiveHelper
    do {
        live = try launchLiveHelper(worker: worker.worker, python: worker.python,
                                    named: "jobfields")
    } catch {
        check(false, "O: the helper starts for job submission", "\(error)")
        return
    }
    defer { live.stopIfNeeded() }
    guard live.ready != nil else {
        check(false, "O: the helper is ready", live.logTail)
        return
    }
    let pixel: URL
    do {
        pixel = try writeLivePixel(live.inputs)
    } catch {
        check(false, "O: an input image is written in the allowed root", "\(error)")
        return
    }
    let client = live.client
    let image: [String: Any] = ["image": ["path": pixel.path]]

    func refusal(_ capability: String) -> AIWorkerFailure? {
        do {
            _ = try client.submit("upscale", image, capability: capability)
            return nil
        } catch let failure as AIWorkerFailure {
            return failure
        } catch {
            return AIWorkerFailure(code: 0, message: "unexpected \(error)")
        }
    }

    // The worker's own report supplies both the state and the sentence, so a
    // reworded reason cannot quietly desynchronise this file from the adapter.
    let listed = (try? client.call("capability.list", timeout: 20)) as? [String: Any] ?? [:]
    let records = (listed["capabilities"] as? [[String: Any]]) ?? []
    func published(_ capability: String) -> [String: Any]? {
        records.first { $0["capabilityId"] as? String == capability }
    }
    check(published("upscale.2x")?["state"] as? String == "unsupported",
          "O: 2× is unsupported in the worker's own report")
    check(published("upscale.4x")?["state"] as? String == "requires_model",
          "O: 4× needs weights this models root does not have")

    let two = refusal("upscale.2x")
    check(two?.code == -32020 && two?.typedCode == "E_UNSUPPORTED",
          "O: naming 2× is refused as unsupported", two?.message ?? "")
    check(two?.message == published("upscale.2x")?["reason"] as? String,
          "O: the line the UI shows is the worker's reason for that state",
          two?.message ?? "")

    let four = refusal("upscale.4x")
    check(four?.code == -32011 && four?.typedCode == "E_MODEL_MISSING",
          "O: naming 4× without weights opens the model manager",
          four?.message ?? "")
    check(four?.message == published("upscale.4x")?["reason"] as? String,
          "O: a missing-model refusal names the model", four?.message ?? "")

    // The gate filters the frozen table by job kind, so an id that exists under
    // another kind must not pass: the kind is what the worker looks up.
    let wrongKind = refusal("inpaint.object")
    check(wrongKind?.code == -32020
              && wrongKind?.message.contains("is not a upscale capability") == true,
          "O: an id belonging to another job kind does not pass the gate",
          wrongKind?.message ?? "")
    let invented = refusal("upscale.8x")
    check(invented?.code == -32020,
          "O: an id outside the frozen vocabulary is refused",
          invented?.message ?? "")

    // `capability.list` is also the only place the vocabulary is written, so the
    // id used above as the wrong-kind sample really is a capability of another
    // kind rather than a typo this section invented.
    check(published("inpaint.object")?["capabilityId"] as? String == "inpaint.object",
          "O: the wrong-kind sample is a published capability")

    // Every refusal above happens before `manager.submit`, so none may leave a
    // job folder or a job record. That is the difference between a gate and a
    // job that fails early: an early failure still costs a workdir and a slot.
    let refusedFolders = ((try? FileManager.default.contentsOfDirectory(atPath: live.jobs.path))
                          ?? ["unreadable"]).sorted()
    check(refusedFolders.isEmpty, "O: a capability refusal creates no job folder",
          refusedFolders.joined(separator: " "))
    let snapshot = (try? client.call("jobs.list", timeout: 20)) as? [String: Any] ?? [:]
    check((snapshot["jobs"] as? [[String: Any]])?.isEmpty == true
              && (snapshot["current"] == nil || snapshot["current"] is NSNull),
          "O: a capability refusal creates no job record", "\(snapshot)")

    // A job the gate accepts really runs. `ping` needs no weights, so it lands
    // the same way here and in CI, and the frame it returns is read through the
    // names `wait` and the export were written with.
    let pongJob: String
    do {
        pongJob = try client.submit("ping", image)
    } catch {
        check(false, "O: a kind-only submit keeps the unchanged job path", "\(error)")
        return
    }
    check(!pongJob.isEmpty, "O: the id field the host reads is job_id", pongJob)
    var pong: [String: Any]?
    var pongFailure: AIWorkerFailure?
    do {
        pong = try client.wait(job: pongJob, timeout: 30)
    } catch let failure as AIWorkerFailure {
        pongFailure = failure
    } catch {
        pongFailure = AIWorkerFailure(code: 0, message: "\(error)")
    }
    check(pongFailure == nil && pong?["status"] as? String == "succeeded",
          "O: a succeeded job reports through the status field the host polls",
          pongFailure?.message ?? "\(pong ?? [:])")
    check((pong?["result"] as? [String: Any])?["pong"] as? Bool == true,
          "O: the payload the export reads sits under result")

    // A kind the engine does not have is accepted by the gate and fails inside
    // the job. Its code, -32602, is not the host's -32603 default for an
    // unreadable reply, so agreeing on it proves the read rather than a guess.
    let unknownJob: String
    do {
        unknownJob = try client.submit("w5NoSuchKind", image)
    } catch {
        check(false, "O: an unknown kind is accepted as a job", "\(error)")
        return
    }
    var jobFailure: AIWorkerFailure?
    do {
        _ = try client.wait(job: unknownJob, timeout: 30)
        check(false, "O: an unknown kind does not succeed")
    } catch let failure as AIWorkerFailure {
        jobFailure = failure
    } catch {
        jobFailure = AIWorkerFailure(code: 0, message: "\(error)")
    }
    check(jobFailure?.code == -32602 && jobFailure?.typedCode == "E_INVALID_INPUT",
          "O: the host surfaces the worker's own job failure code",
          jobFailure?.message ?? "")
    let frame = (try? client.call("job.result", ["job_id": unknownJob], timeout: 20))
        as? [String: Any] ?? [:]
    let errorFrame = frame["error"] as? [String: Any]
    check(errorFrame?["code"] as? Int == jobFailure?.code
              && errorFrame?["message"] as? String == jobFailure?.message,
          "O: error.code and error.message are the fields the host reads",
          "\(errorFrame ?? [:])")
    let ranFolders = ((try? FileManager.default.contentsOfDirectory(atPath: live.jobs.path))
                      ?? []).sorted()
    check(ranFolders.contains(unknownJob),
          "O: an accepted job gets the workdir named by its id",
          ranFolders.joined(separator: " "))
}

// MARK: - Run

testRegistryRecordAndCAS()
testExclusiveLeaseExcludesConsumers()
testIdentityDistinguishesLiveness()
testChildOwnedLeaseSurvivesParentDeath()
testShutdownOwnershipCAS()
testLockFileHardening()
testStalePreparingReplacementHoldsExclusiveLease()
testRealHelperHandshake()
testWorkerPublishedPairIsAdoptedByHost()
testHostJobSubmissionAgainstLiveWorker()

try? FileManager.default.removeItem(at: rootDirectory)

print("\n" + String(repeating: "-", count: 60))
if failures.isEmpty {
    print("RUNTIME V2 TESTS: PASS")
    exit(0)
} else {
    print("RUNTIME V2 TESTS: FAIL (\(failures.count))")
    for failure in failures { print("   - \(failure)") }
    exit(1)
}
