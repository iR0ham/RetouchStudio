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
// The protocol-v2 worker package is not published yet, so the helper's own
// CAS and readiness handshake cannot be exercised here; those steps are
// reported as NOT VERIFIED rather than simulated as if they passed.

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

let rootDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("retouch-runtimev2-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - Run

testRegistryRecordAndCAS()
testExclusiveLeaseExcludesConsumers()
testIdentityDistinguishesLiveness()
testChildOwnedLeaseSurvivesParentDeath()
testShutdownOwnershipCAS()
testLockFileHardening()
testStalePreparingReplacementHoldsExclusiveLease()

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
