using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using RetouchStudio.AI.Models;

namespace RetouchStudio.AI.Tests;

/// <summary>
/// W5-2 conformance on Windows: a loopback HTTP server, real child processes for
/// leases and crashes, and the same catalog fixtures the macOS suite uses.
/// </summary>
public static class ModelStoreChecks
{
    private static string FixtureDirectory =>
        Path.Combine(Environment.GetEnvironmentVariable("RETOUCH_TESTS_ROOT")
                     ?? FindRepositoryRoot(), "Tests", "Fixtures", "model-store");

    private static string RepositoryRoot =>
        Environment.GetEnvironmentVariable("RETOUCH_TESTS_ROOT") ?? FindRepositoryRoot();

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "Tests", "Fixtures")))
                return directory.FullName;
            directory = directory.Parent;
        }
        return Directory.GetCurrentDirectory();
    }

    // MARK: - Child modes

    public static void RunChildIfRequested(string[] args)
    {
        if (args.Length == 0) return;
        try
        {
            switch (args[0])
            {
                case "--hold-lock":
                {
                    var path = args[1];
                    var exclusive = args[2] == "ex";
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    if (!File.Exists(path)) File.WriteAllBytes(path, Array.Empty<byte>());
                    using var stream = exclusive
                        ? new FileStream(path, FileMode.Open, FileAccess.ReadWrite,
                            FileShare.None)
                        : new FileStream(path, FileMode.Open, FileAccess.Read,
                            FileShare.Read);
                    Console.WriteLine("locked");
                    Console.Out.Flush();
                    Thread.Sleep(TimeSpan.FromSeconds(double.Parse(args[3])));
                    Environment.Exit(0);
                    return;
                }
                case "--install-once":
                {
                    var catalog = LoadExpandedCatalog(args[1], args[4]);
                    var entry = catalog.Entry(args[3]) ?? throw new InvalidOperationException("no entry");
                    var store = new ModelStore(args[2], catalog, "windows-x64",
                        allowLocalHttp: true);
                    try
                    {
                        store.InstallAsync(entry).GetAwaiter().GetResult();
                        Console.WriteLine("installed");
                        Environment.Exit(0);
                    }
                    catch (ModelStoreError error)
                    {
                        Console.WriteLine($"code={error.Code} {error.Message}");
                        Environment.Exit(error.Code == "E_MODEL_LEASED" ? 3 : 2);
                    }
                    return;
                }
                case "--delete-once":
                {
                    var catalog = LoadExpandedCatalog(args[1], args[5]);
                    var entry = catalog.Entry(args[3]) ?? throw new InvalidOperationException("no entry");
                    var store = new ModelStore(args[2], catalog, "windows-x64",
                        allowLocalHttp: true);
                    try
                    {
                        store.Delete(entry, args[4]);
                        Console.WriteLine("deleted");
                        Environment.Exit(0);
                    }
                    catch (ModelStoreError error)
                    {
                        Console.WriteLine($"code={error.Code}");
                        Environment.Exit(2);
                    }
                    return;
                }
            }
        }
        catch (Exception error)
        {
            Console.WriteLine(error);
            Environment.Exit(64);
        }
    }

    // MARK: - Entry point

    private static Action<bool, string, string?> _check = (_, _, _) => { };
    private static int _failures;

    private static void C(bool condition, string label, string? detail = null)
    {
        _check(condition, label, detail);
        if (!condition) _failures++;
    }

    public static void Run(Action<bool, string, string?> check)
    {
        _check = check;
        _failures = 0;
        RunCatalog();
        RunNoNetwork();
        RunInstall();
        RunBadBytes();
        RunInterruption();
        RunCancellation();
        RunDisk();
        RunSourceAndReparse();
        RunLeases();
        RunDelete();
        RunUpdateRollback();
        RunConcurrentInstalls();
        RunCrashBoundaries();
        RunCleanup();
        RunPointers();
        RunLegacy();
        RunProductionCatalog();
        Console.WriteLine(_failures == 0
            ? "MODEL STORE CHECKS: PASS"
            : $"MODEL STORE CHECKS: FAIL ({_failures})");
    }

    // MARK: - Sections

    private static void RunCatalog()
    {
        Console.WriteLine("[M1] shared catalog: mandatory metadata, DR-5, source rules");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        server.Serve("/v2/payload.bin", "fixture-two\n");
        var valid = LoadCatalog("catalog-valid.json", server.Base);
        C(valid.Entries.Count == 4, "installable fixture catalog decodes");
        var good = valid.Entry("fixture-good")!;
        C(good.IsVerifiable, "complete entry is verifiable");
        var unverifiable = valid.Entry("fixture-unverifiable")!;
        C(!unverifiable.IsVerifiable && unverifiable.SizeBytes is null &&
          unverifiable.Sha256 is null, "null size/hash is unverifiable (DR-5)");
        var full = JsonDocument.Parse(File.ReadAllText(
            Path.Combine(FixtureDirectory, "catalog-fixture.json")));
        C(full.RootElement.GetProperty("entries").GetArrayLength() == 7,
            "full fixture lists the rejected cases");
        C(!tryLoadFull(server.Base), "a catalog with an insecure entry is rejected as a whole");
        foreach (var id in new[] { "fixture-http", "fixture-offhost", "fixture-traversal" })
            C(!TryLoadSingle(id, server.Base), $"{id} is rejected at catalog load");
    }

    private static void RunNoNetwork()
    {
        Console.WriteLine("[M2] snapshot/verify/cleanup never touch the network");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        _ = store.Records();
        _ = store.DiskUsage();
        _ = store.AvailableBytes();
        _ = store.Cleanup(DateTime.UtcNow.AddHours(48));
        try
        {
            _ = store.Verify(store.Catalog.Entry("fixture-good")!, "1.0.0", true);
            C(false, "verify reports a missing version");
        }
        catch (ModelStoreError error)
        {
            C(error.Code == "E_MODEL_MISSING", "verify reports E_MODEL_MISSING");
        }
        C(server.Count == 0, "zero HTTP requests outside an approved install",
            $"{server.Count}");
    }

    private static void RunInstall()
    {
        Console.WriteLine("[M3] staged install, manifest, atomic pointer, retry");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        var progress = 0;
        var result = store.InstallAsync(entry,
            new SyncProgress<ModelTransferProgress>(_ => Interlocked.Increment(ref progress)))
            .GetAwaiter().GetResult();
        C(result.Version == "1.0.0", "install succeeds");
        C(store.ActivePointer("fixture-good")?.Version == "1.0.0",
            "pointer names the installed version");
        var manifestPath = store.Layout.ManifestPath("fixture-good", "1.0.0");
        C(File.Exists(manifestPath), "manifest exists");
        C(!StagingDirs(store).Any(),
            "staging is empty after success");
        C(server.Count == 1, "exactly the catalog file was fetched", $"{server.Count}");
        C(Volatile.Read(ref progress) > 0, "progress was reported");
        var report = store.Verify(entry, "1.0.0", true);
        C(report.Ok && report.Checked == 1, "full verify passes");
        var record = store.Records().First(r => r.Id == "fixture-good");
        C(record.ActiveVersion == "1.0.0" && record.Versions.Count == 1,
            "snapshot shows one active version");
        var before = server.Count;
        store.InstallAsync(entry).GetAwaiter().GetResult();
        C(server.Count == before, "verified reinstall downloads nothing");
        C(store.InstalledVersions(entry).Count == 1, "reinstall does not duplicate");
    }

    private static void RunBadBytes()
    {
        Console.WriteLine("[M4] SHA mismatch, size mismatch, unverifiable metadata");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        ExpectCode(() => store.InstallAsync(store.Catalog.Entry("fixture-sha")!).GetAwaiter().GetResult(),
            "E_MODEL_UNVERIFIED", "SHA mismatch is refused", C);
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-sha", "1.0.0")),
            "no version from a SHA mismatch");
        ExpectCode(() => store.InstallAsync(store.Catalog.Entry("fixture-size")!).GetAwaiter().GetResult(),
            "E_MODEL_UNVERIFIED", "size mismatch is refused", C);
        var before = server.Count;
        ExpectCode(() => store.InstallAsync(
                store.Catalog.Entry("fixture-unverifiable")!).GetAwaiter().GetResult(),
            "E_MODEL_UNVERIFIED", "unverifiable entry is refused before any byte", C);
        C(server.Count == before, "unverifiable entry made no request");
        C(!StagingDirs(store).Any(),
            "failed downloads left no staging tree");

        var corruptStore = MakeStore(server);
        var corruptEntry = corruptStore.Catalog.Entry("fixture-good")!;
        corruptStore.InstallAsync(corruptEntry).GetAwaiter().GetResult();
        File.WriteAllText(corruptStore.Layout.ManifestPath("fixture-good", "1.0.0"), "{}");
        C(!corruptStore.Verify(corruptEntry, "1.0.0", true).Ok,
            "a corrupt manifest fails verification");
        ExpectCode(() => corruptStore.Activate(corruptEntry, "1.0.0"),
            "E_MODEL_UNVERIFIED", "a corrupt manifest cannot be activated", C);
    }

    private static void RunInterruption()
    {
        Console.WriteLine("[M5] interruption and safe retry");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n", dropAfter: 4);
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        ExpectCode(() => store.InstallAsync(entry).GetAwaiter().GetResult(),
            "E_INVALID_INPUT", "a dropped connection is a typed failure", C);
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "no version after interruption");
        C(!StagingDirs(store).Any(),
            "staging is cleaned after interruption");
        server.Serve("/good/payload.bin", "fixture-one\n");
        store.InstallAsync(entry).GetAwaiter().GetResult();
        C(store.Verify(entry, "1.0.0", true).Ok, "retry after the network returns succeeds");
    }

    private static void RunCancellation()
    {
        Console.WriteLine("[M6] cancellation leaves nothing installed");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n", delayMilliseconds: 60);
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        using var cancel = new CancellationTokenSource();
        var task = store.InstallAsync(entry, cancellationToken: cancel.Token);
        Thread.Sleep(250);
        cancel.Cancel();
        ExpectCode(() => task.GetAwaiter().GetResult(), "E_CANCELLED",
            "cancellation is E_CANCELLED", C);
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "cancellation installed no version");
        C(!StagingDirs(store).Any(),
            "cancellation cleaned staging");
        C(store.ActivePointer("fixture-good") is null, "cancellation wrote no pointer");
    }

    private static void RunDisk()
    {
        Console.WriteLine("[M7] insufficient disk is refused before any request");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        var huge = long.MaxValue / 2;
        var entry = new ModelCatalogEntry
        {
            Id = "fixture-huge",
            Name = "huge",
            Capabilities = new List<string> { "upscale.4x" },
            Version = "1.0.0",
            Format = "fixture",
            Files = new List<ModelCatalogFile>
            {
                new()
                {
                    Path = "payload.bin", SizeBytes = huge,
                    Sha256 = new string('a', 64),
                    SourceUrl = server.Base + "/good/payload.bin",
                },
            },
            SizeBytes = huge,
            Sha256 = new string('b', 64),
            SourceUrl = server.Base + "/good",
            CodeLicense = "MIT",
            WeightsLicense = "MIT",
            LicenseEvidenceUrl = server.Base + "/good",
            Platforms = new List<string> { "windows-x64" },
            RequiredProvider = "cpu",
            MinimumContractVersion = "1",
            Preprocess = new ModelPreprocess { Id = "fixture", Version = "1" },
            Deterministic = true,
        };
        var before = server.Count;
        ExpectCode(() => store.InstallAsync(entry).GetAwaiter().GetResult(),
            "E_INVALID_INPUT", "disk check refuses an impossible size", C);
        C(server.Count == before, "disk refusal made no request");
    }

    private static void RunSourceAndReparse()
    {
        Console.WriteLine("[M8] production refuses loopback HTTP; junctions are refused");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var production = MakeStore(server, allowLocalHttp: false);
        ExpectCode(() => production.InstallAsync(
                production.Catalog.Entry("fixture-good")!).GetAwaiter().GetResult(),
            "E_INVALID_INPUT", "store without local-HTTP opt-in refuses the test source", C);

        var store = MakeStore(server);
        Directory.CreateDirectory(store.Layout.Root);
        var outside = Path.Combine(Path.GetTempPath(), $"rs-outside-{Guid.NewGuid():N}");
        Directory.CreateDirectory(outside);
        if (Directory.Exists(store.Layout.Staging)) Directory.Delete(store.Layout.Staging);
        C(TryCreateJunction(store.Layout.Staging, outside), "a junction was created for the escape test");
        ExpectCode(() => store.InstallAsync(
                store.Catalog.Entry("fixture-good")!).GetAwaiter().GetResult(),
            "E_INVALID_INPUT", "a junctioned .staging is refused", C);
        C(!Directory.EnumerateFileSystemEntries(outside).Any(),
            "nothing was written through the junction");
    }

    private static void RunLeases()
    {
        Console.WriteLine("[M9] leases: shared reader, exclusive delete/install, death release");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        store.InstallAsync(entry).GetAwaiter().GetResult();
        var lockPath = store.Layout.LockPath("fixture-good", "1.0.0");

        var (reader, readerLine) = LaunchHolder(lockPath, false);
        C(readerLine == "locked", "child holds a real shared handle");
        ExpectCode(() => store.Delete(entry, "1.0.0"), "E_MODEL_LEASED",
            "delete refuses while a job holds a shared lease", C);
        ExpectCode(() => store.InstallAsync(entry).GetAwaiter().GetResult(),
            "E_MODEL_LEASED", "install refuses while a reader holds the version", C);
        C(store.Verify(entry, "1.0.0", true).Ok, "verify works under a shared lease");
        Stop(reader);
        reader.WaitForExit();
        Thread.Sleep(100);
        store.Delete(entry, "1.0.0");
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "death released the lease; delete proceeds");

        store.InstallAsync(entry).GetAwaiter().GetResult();
        var (writer, writerLine) = LaunchHolder(lockPath, true);
        C(writerLine == "locked", "child holds a real exclusive handle");
        ExpectCode(() => store.Verify(entry, "1.0.0", true), "E_MODEL_LEASED",
            "verify needs a shared lease and is refused", C);
        Stop(writer);
        writer.WaitForExit();
    }

    private static void RunDelete()
    {
        Console.WriteLine("[M10] delete removes the pointer and the version");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        server.Serve("/good/payload.bin", "fixture-one\n", delayMilliseconds: 100);
        var catalog = Path.Combine(FixtureDirectory, "catalog-valid.json");
        var downloading = StartInstall(catalog, store.Layout.Root, "fixture-good",
            server.Base);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline &&
               !StagingDirs(store).Any())
            Thread.Sleep(20);
        ExpectCode(() => store.Delete(entry, "1.0.0"), "E_MODEL_LEASED",
            "delete refuses while a download holds the version", C);
        Stop(downloading);
        downloading.WaitForExit();
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "killed download installed nothing");
        server.Serve("/good/payload.bin", "fixture-one\n");
        store.InstallAsync(entry).GetAwaiter().GetResult();
        store.Delete(entry, "1.0.0");
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "version directory is gone");
        C(store.ActivePointer("fixture-good") is null, "active pointer is gone");
        C(!Directory.Exists(store.Layout.Quarantine) ||
          !Directory.EnumerateDirectories(store.Layout.Quarantine).Any(),
            "quarantine was emptied");
        ExpectCode(() => store.Delete(entry, "1.0.0"), "E_MODEL_MISSING",
            "deleting a missing version is typed", C);
    }

    private static void RunUpdateRollback()
    {
        Console.WriteLine("[M11] update beside a leased old version; rollback switches the pointer");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        server.Serve("/v2/payload.bin", "fixture-two\n");
        var store = MakeStore(server);
        var v1 = store.Catalog.Entry("fixture-good")!;
        var v2 = LoadCatalog("catalog-fixture-v2.json", server.Base).Entry("fixture-good")!;
        store.InstallAsync(v1).GetAwaiter().GetResult();
        var lock1 = store.Layout.LockPath("fixture-good", "1.0.0");
        var (oldJob, oldLine) = LaunchHolder(lock1, false);
        C(oldLine == "locked", "a job holds the old version");
        store.InstallAsync(v2).GetAwaiter().GetResult();
        C(store.InstalledVersions(v1).Count == 2, "update kept both versions");
        C(store.ActivePointer("fixture-good")?.Version == "2.0.0", "update switched the pointer");
        C(Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "the running job's files were not moved");
        ExpectCode(() => store.Delete(v1, "1.0.0"), "E_MODEL_LEASED",
            "delete of a version in use is refused", C);
        Stop(oldJob);
        oldJob.WaitForExit();

        var lock2 = store.Layout.LockPath("fixture-good", "2.0.0");
        var (newJob, newLine) = LaunchHolder(lock2, false);
        C(newLine == "locked", "a job holds the new version");
        var downloads = server.Count;
        store.Activate(v1, "1.0.0");
        C(store.ActivePointer("fixture-good")?.Version == "1.0.0",
            "rollback works while a job holds another version");
        C(server.Count == downloads, "rollback downloaded nothing");
        C(Directory.Exists(store.Layout.VersionDirectory("fixture-good", "2.0.0")),
            "the running job's version stayed intact");
        Stop(newJob);
        newJob.WaitForExit();
        Thread.Sleep(100);

        store.Activate(v2, "2.0.0");
        File.WriteAllText(Path.Combine(
            store.Layout.VersionDirectory("fixture-good", "1.0.0"), "payload.bin"), "corrupt");
        ExpectCode(() => store.Activate(v1, "1.0.0"), "E_MODEL_UNVERIFIED",
            "rollback refuses a corrupt target", C);
        C(store.ActivePointer("fixture-good")?.Version == "2.0.0",
            "failed rollback left the pointer on the good version");
    }

    private static void RunConcurrentInstalls()
    {
        Console.WriteLine("[M12] two child processes installing the same version");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n", delayMilliseconds: 60);
        var store = MakeStore(server);
        var catalog = Path.Combine(FixtureDirectory, "catalog-valid.json");
        var first = StartInstall(catalog, store.Layout.Root, "fixture-good", server.Base);
        Thread.Sleep(150);
        var second = StartInstall(catalog, store.Layout.Root, "fixture-good", server.Base);
        first.WaitForExit();
        second.WaitForExit();
        var statuses = new[] { first.ExitCode, second.ExitCode }.OrderBy(x => x).ToArray();
        C(statuses.SequenceEqual(new[] { 0, 3 }),
            "one installed and the other was refused as leased",
            string.Join(",", statuses));
        C(store.Verify(store.Catalog.Entry("fixture-good")!, "1.0.0", true).Ok,
            "the winning install is complete");
        C(!StagingDirs(store).Any(),
            "no staging debris from the losing process");
    }

    private static void RunCrashBoundaries()
    {
        Console.WriteLine("[M13] crash after verification, rename, pointer removal and during download");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var catalog = Path.Combine(FixtureDirectory, "catalog-valid.json");

        var a = MakeStore(server);
        var crashA = StartInstall(catalog, a.Layout.Root, "fixture-good", server.Base,
            "after-verify");
        crashA.WaitForExit();
        C(crashA.ExitCode == 86, "child died after verification", $"{crashA.ExitCode}");
        C(!Directory.Exists(a.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "no version before the rename");
        C(StagingDirs(a).Any(),
            "the verified staging tree survived the crash");
        a.InstallAsync(a.Catalog.Entry("fixture-good")!).GetAwaiter().GetResult();
        C(a.ActivePointer("fixture-good")?.Version == "1.0.0", "restart installed and activated");
        foreach (var child in StagingDirs(a))
            Directory.SetLastWriteTimeUtc(child, DateTime.UtcNow.AddHours(-25));
        _ = a.Cleanup(DateTime.UtcNow.AddHours(2));
        C(!StagingDirs(a).Any(),
            "aged crash staging is reclaimed");
        C(Directory.Exists(a.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "cleanup left the installed version");

        var b = MakeStore(server);
        var crashB = StartInstall(catalog, b.Layout.Root, "fixture-good", server.Base,
            "after-rename");
        crashB.WaitForExit();
        C(crashB.ExitCode == 86, "child died after the rename", $"{crashB.ExitCode}");
        C(Directory.Exists(b.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "version directory survived");
        C(b.ActivePointer("fixture-good") is null, "pointer was not written");
        var recordB = b.Records().First(r => r.Id == "fixture-good");
        C(recordB.Versions.Count == 1 && recordB.ActiveVersion is null,
            "snapshot shows the inactive version");
        var downloadsB = server.Count;
        b.InstallAsync(b.Catalog.Entry("fixture-good")!).GetAwaiter().GetResult();
        C(server.Count == downloadsB, "restart used verified files, not the network");

        var d = MakeStore(server);
        d.InstallAsync(d.Catalog.Entry("fixture-good")!).GetAwaiter().GetResult();
        var crashD = StartDelete(catalog, d.Layout.Root, "fixture-good", "1.0.0",
            server.Base, "after-pointer-removal");
        crashD.WaitForExit();
        C(crashD.ExitCode == 86, "delete child died after removing the pointer",
            $"{crashD.ExitCode}");
        C(d.ActivePointer("fixture-good") is null, "pointer is gone");
        C(Directory.Exists(d.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "files survived the delete crash");
        d.Delete(d.Catalog.Entry("fixture-good")!, "1.0.0");
        C(!Directory.Exists(d.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "a repeated delete completes the interrupted one");

        var e = MakeStore(server);
        server.Serve("/good/payload.bin", "fixture-one\n", delayMilliseconds: 100);
        var slow = StartInstall(catalog, e.Layout.Root, "fixture-good", server.Base);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (DateTime.UtcNow < deadline &&
               !StagingDirs(e).Any())
            Thread.Sleep(20);
        Thread.Sleep(300);
        Stop(slow);
        slow.WaitForExit();
        C(!Directory.Exists(e.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "killed download installed nothing");
        foreach (var child in StagingDirs(e))
            Directory.SetLastWriteTimeUtc(child, DateTime.UtcNow.AddHours(-25));
        _ = e.Cleanup(DateTime.UtcNow.AddHours(2));
        C(!StagingDirs(e).Any(),
            "identity-less stale staging is reclaimed");
        server.Serve("/good/payload.bin", "fixture-one\n");
        e.InstallAsync(e.Catalog.Entry("fixture-good")!).GetAwaiter().GetResult();
        C(e.Verify(e.Catalog.Entry("fixture-good")!, "1.0.0", true).Ok,
            "a fresh install succeeds after the killed one");
    }

    private static void RunCleanup()
    {
        Console.WriteLine("[M14] cleanup: grace, live lease, unidentifiable trees");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        Directory.CreateDirectory(store.Layout.Staging);
        Directory.CreateDirectory(store.Layout.Quarantine);
        Directory.CreateDirectory(store.Layout.Locks);
        var young = Path.Combine(store.Layout.Staging, "young-" + Guid.NewGuid().ToString("N"));
        WriteManifest(young, "fixture-good", "0.7.0");
        var stale = Path.Combine(store.Layout.Staging, "stale-" + Guid.NewGuid().ToString("N"));
        WriteManifest(stale, "fixture-good", "0.9.0");
        Directory.SetLastWriteTimeUtc(stale, DateTime.UtcNow.AddHours(-25));
        var unreadable = Path.Combine(store.Layout.Staging, "none-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(unreadable);
        Directory.SetLastWriteTimeUtc(unreadable, DateTime.UtcNow.AddHours(-25));
        var locked = Path.Combine(store.Layout.Staging, "locked-" + Guid.NewGuid().ToString("N"));
        WriteManifest(locked, "fixture-good", "9.9.0");
        Directory.SetLastWriteTimeUtc(locked, DateTime.UtcNow.AddHours(-25));
        var staleLock = Path.Combine(store.Layout.Staging,
            "stale-lock-" + Guid.NewGuid().ToString("N"));
        WriteManifest(staleLock, "fixture-good", "0.6.0");
        Directory.SetLastWriteTimeUtc(staleLock, DateTime.UtcNow.AddHours(-25));
        File.WriteAllBytes(store.Layout.LockPath("fixture-good", "0.6.0"),
            Array.Empty<byte>());
        var quarantine = Path.Combine(store.Layout.Quarantine, "q-1");
        WriteManifest(quarantine, "fixture-good", "0.8.0");
        Directory.SetLastWriteTimeUtc(quarantine, DateTime.UtcNow.AddHours(-25));
        var unknown = Path.Combine(store.Layout.Quarantine,
            "unknown-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(unknown);
        Directory.SetLastWriteTimeUtc(unknown, DateTime.UtcNow.AddHours(-25));

        var lockPath = store.Layout.LockPath("fixture-good", "9.9.0");
        var (holder, line) = LaunchHolder(lockPath, true);
        C(line == "locked", "cleanup test holds a real lease");
        var decisions = store.Cleanup(DateTime.UtcNow.AddHours(2));
        C(Directory.Exists(young), "young staging is kept");
        C(!Directory.Exists(stale), "stale identified staging is removed");
        C(!Directory.Exists(unreadable), "stale identity-less staging is removed");
        C(Directory.Exists(locked), "stale staging under a live lease is kept");
        C(!Directory.Exists(staleLock),
            "stale staging whose lock file is no longer held is removed");
        C(!Directory.Exists(quarantine), "older identified quarantine is removed");
        C(Directory.Exists(unknown), "quarantine without identity is kept");
        C(decisions.Any(d => d.Action == "keep" && d.Reason.Contains("live lease")),
            "a live-lease decision is recorded");
        Stop(holder);
        holder.WaitForExit();
    }

    private static void RunPointers()
    {
        Console.WriteLine("[M15] atomic pointer replacement and dangling pointers");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        server.Serve("/v2/payload.bin", "fixture-two\n");
        var store = MakeStore(server);
        var v1 = store.Catalog.Entry("fixture-good")!;
        var v2 = LoadCatalog("catalog-fixture-v2.json", server.Base).Entry("fixture-good")!;
        store.InstallAsync(v1).GetAwaiter().GetResult();
        store.InstallAsync(v2).GetAwaiter().GetResult();
        try
        {
            Parallel.For(0, 40, index =>
            {
                if (index % 2 == 0) store.Activate(v1, "1.0.0");
                else store.Activate(v2, "2.0.0");
            });
        }
        catch (AggregateException error)
        {
            C(false, "concurrent pointer writes completed", error.InnerException?.Message);
        }
        var pointer = JsonSerializer.Deserialize<ModelActivePointer>(
            File.ReadAllText(store.Layout.ActivePath("fixture-good")),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        C(pointer is not null && new[] { "1.0.0", "2.0.0" }.Contains(pointer.Version),
            "concurrent writes leave one valid pointer", pointer?.Version);
        C(!Directory.EnumerateFiles(store.Layout.ModelDirectory("fixture-good"))
                .Any(path => path.EndsWith(".tmp")),
            "atomic writes leave no temporary files");
        File.WriteAllText(store.Layout.ActivePath("fixture-good"),
            JsonSerializer.Serialize(new ModelActivePointer
            {
                Schema = ModelActivePointer.SchemaName, ModelId = "fixture-good",
                Version = "9.9.9", ManifestSha256 = "0", ActivatedAt = 0,
            }));
        var record = store.Records().First(r => r.Id == "fixture-good");
        C(record.ActiveVersion is null, "a dangling pointer is not reported as active");
        store.InstallAsync(v1).GetAwaiter().GetResult();
        C(store.ActivePointer("fixture-good")?.Version == "1.0.0",
            "reinstalling an existing version repairs the pointer");
    }

    private static void RunLegacy()
    {
        Console.WriteLine("[M16] verified flat installs are adopted without network");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        var flat = store.Layout.ModelDirectory("fixture-good");
        Directory.CreateDirectory(flat);
        File.WriteAllText(Path.Combine(flat, "payload.bin"), "fixture-one\n");
        C(store.LegacyBytes(entry) == 12, "legacy bytes are detected");
        C(server.Count == 0, "detection made no request");
        store.MigrateLegacyAsync(entry).GetAwaiter().GetResult();
        C(server.Count == 0, "adoption used hashes, not the network");
        C(!File.Exists(Path.Combine(flat, "payload.bin")), "flat file was moved");
        C(store.ActivePointer("fixture-good")?.Version == "1.0.0", "adopted version is active");
        C(store.Verify(entry, "1.0.0", true).Ok, "adopted version verifies");

        var bad = MakeStore(server);
        var badEntry = bad.Catalog.Entry("fixture-good")!;
        var badFlat = bad.Layout.ModelDirectory("fixture-good");
        Directory.CreateDirectory(badFlat);
        File.WriteAllText(Path.Combine(badFlat, "payload.bin"), "different\n");
        ExpectCode(() => bad.MigrateLegacyAsync(badEntry).GetAwaiter().GetResult(),
            "E_MODEL_UNVERIFIED", "a mismatching flat file is not adopted", C);
        C(File.Exists(Path.Combine(badFlat, "payload.bin")),
            "the mismatching file stayed where it was");
    }

    private static void RunProductionCatalog()
    {
        Console.WriteLine("[M17] shipped catalog: DR-5, capability and platform facts");
        var path = Path.Combine(RepositoryRoot, "Resources", "model-catalog.json");
        var catalog = ModelCatalog.Load(path);
        C(catalog.Entries.Count >= 4, "shipped catalog loads", $"{catalog.Entries.Count}");
        C(catalog.Entry("sam2.1-hiera-tiny")?.IsVerifiable == false,
            "SAM 2.1 is listed but unverifiable");
        C(catalog.Entry("swin2sr-x4")?.Supports("windows-x64") == false,
            "Swin2SR is not advertised on Windows");
        C(catalog.Entry("migan")?.Supports("windows-x64") == true,
            "MI-GAN is advertised on Windows");
        C(catalog.Entries.All(e => e.LicenseEvidenceUrl.StartsWith("https://",
            StringComparison.OrdinalIgnoreCase)),
            "every shipped entry has an HTTPS licence evidence URL");
    }

    // MARK: - Helpers

    private static ModelCatalog LoadCatalog(string name, string baseUrl) =>
        ModelCatalog.LoadJson(File.ReadAllText(Path.Combine(FixtureDirectory, name))
            .Replace("{base}", baseUrl), allowLocalHttp: true);

    private static ModelCatalog LoadExpandedCatalog(string path, string baseUrl) =>
        ModelCatalog.LoadJson(File.ReadAllText(path).Replace("{base}", baseUrl),
            allowLocalHttp: true);

    private static bool tryLoadFull(string baseUrl)
    {
        try
        {
            _ = LoadExpandedCatalog(Path.Combine(FixtureDirectory, "catalog-fixture.json"),
                baseUrl);
            return true;
        }
        catch (ModelStoreError)
        {
            return false;
        }
    }

    private static bool TryLoadSingle(string id, string baseUrl)
    {
        try
        {
            var document = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(FixtureDirectory, "catalog-fixture.json"))).RootElement;
            var entries = document.GetProperty("entries").EnumerateArray()
                .Where(e => e.GetProperty("id").GetString() == id)
                .Select(e => e.GetRawText());
            var json = $$"""{"schema":"retouchstudio.model-catalog/1","catalogVersion":"fixture-1","entries":[{{string.Join(",", entries)}}]}""";
            _ = ModelCatalog.LoadJson(json.Replace("{base}", baseUrl), allowLocalHttp: true);
            return true;
        }
        catch (ModelStoreError)
        {
            return false;
        }
    }

    private static string[] StagingDirs(ModelStore store) =>
        Directory.Exists(store.Layout.Staging)
            ? Directory.GetDirectories(store.Layout.Staging)
            : Array.Empty<string>();

    private static ModelStore MakeStore(FixtureServer server, bool allowLocalHttp = true)
    {
        var catalog = LoadCatalog("catalog-valid.json", server.Base);
        var root = Path.Combine(Path.GetTempPath(), $"rsstore-{Guid.NewGuid():N}");
        return new ModelStore(root, catalog, "windows-x64", allowLocalHttp);
    }

    private static void ExpectCode(Action action, string code, string label,
        Action<bool, string, string?> check)
    {
        try
        {
            action();
            check(false, label, $"expected {code}, got success");
        }
        catch (Exception error)
        {
            var actual = error is ModelStoreError storeError
                ? storeError.Code
                : error.GetType().Name;
            check(actual == code, label, actual);
        }
    }

    private static Process StartInstall(string catalog, string root, string id,
        string baseUrl, string? crash = null)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("--install-once");
        start.ArgumentList.Add(catalog);
        start.ArgumentList.Add(root);
        start.ArgumentList.Add(id);
        start.ArgumentList.Add(baseUrl);
        start.Environment["RETOUCH_MODEL_TESTING"] = "1";
        if (crash is not null) start.Environment["RETOUCH_MODEL_TEST_CRASH"] = crash;
        return Process.Start(start)!;
    }

    private static void Stop(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(true);
        }
        catch (InvalidOperationException) { }
    }

    private static Process StartDelete(string catalog, string root, string id,
        string version, string baseUrl, string? crash = null)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("--delete-once");
        start.ArgumentList.Add(catalog);
        start.ArgumentList.Add(root);
        start.ArgumentList.Add(id);
        start.ArgumentList.Add(version);
        start.ArgumentList.Add(baseUrl);
        start.Environment["RETOUCH_MODEL_TESTING"] = "1";
        if (crash is not null) start.Environment["RETOUCH_MODEL_TEST_CRASH"] = crash;
        return Process.Start(start)!;
    }

    private static (Process Process, string? Line) LaunchHolder(string path, bool exclusive)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("--hold-lock");
        start.ArgumentList.Add(path);
        start.ArgumentList.Add(exclusive ? "ex" : "sh");
        start.ArgumentList.Add("60");
        var process = Process.Start(start)!;
        var line = process.StandardOutput.ReadLine();
        return (process, line);
    }

    private static bool TryCreateJunction(string link, string target)
    {
        try
        {
            var start = new ProcessStartInfo("cmd.exe")
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add("/c");
            start.ArgumentList.Add("mklink");
            start.ArgumentList.Add("/J");
            start.ArgumentList.Add(link);
            start.ArgumentList.Add(target);
            using var process = Process.Start(start)!;
            process.WaitForExit();
        }
        catch (Exception)
        {
            // Not Windows (or no cmd.exe); the symlink fallback below proves
            // the same reparse-point rule on this host.
        }
        if (!Directory.Exists(link))
        {
            try { Directory.CreateSymbolicLink(link, target); }
            catch (Exception) { }
        }
        return Directory.Exists(link);
    }

    private static void WriteManifest(string directory, string model, string version)
    {
        Directory.CreateDirectory(directory);
        var manifest = new ModelManifest
        {
            Schema = ModelManifest.SchemaName,
            ModelId = model,
            Version = version,
            CatalogVersion = "fixture-1",
            ManifestSha256 = "0",
            Files = new List<ModelManifestFile>
            {
                new() { Path = "payload.bin", SizeBytes = 12, Sha256 = "0" },
            },
            InstalledAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        };
        File.WriteAllText(Path.Combine(directory, "manifest.json"),
            JsonSerializer.Serialize(manifest));
    }

    private sealed record Route(byte[] Body, int Status, int DelayMilliseconds,
        int? DropAfter);

    private sealed class SyncProgress<T> : IProgress<T>
    {
        private readonly Action<T> _report;

        public SyncProgress(Action<T> report) => _report = report;

        public void Report(T value) => _report(value);
    }

    private sealed class FixtureServer : IDisposable
    {
        private readonly TcpListener _listener;
        private readonly CancellationTokenSource _stop = new();
        private readonly ConcurrentDictionary<string, Route> _routes = new();
        private readonly object _lock = new();
        private readonly List<string> _paths = new();
        private int _count;

        public FixtureServer()
        {
            _listener = new TcpListener(IPAddress.Loopback, 0);
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _ = Task.Run(AcceptLoop);
        }

        public int Port { get; }
        public string Base => $"http://127.0.0.1:{Port}";
        public int Count => Volatile.Read(ref _count);
        public IReadOnlyList<string> Paths
        {
            get { lock (_lock) return _paths.ToArray(); }
        }

        public void Serve(string path, string body, int delayMilliseconds = 0,
            int? dropAfter = null, int status = 200) =>
            _routes[path] = new Route(Encoding.UTF8.GetBytes(body), status,
                delayMilliseconds, dropAfter);

        private async Task AcceptLoop()
        {
            while (!_stop.IsCancellationRequested)
            {
                try
                {
                    var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                    _ = Task.Run(() => Handle(client));
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (SocketException)
                {
                    return;
                }
            }
        }

        private async Task Handle(TcpClient client)
        {
            using (client)
            {
                try
                {
                    var stream = client.GetStream();
                    var request = new MemoryStream();
                    var buffer = new byte[4096];
                    while (request.Length < 16384)
                    {
                        var read = await stream.ReadAsync(buffer, _stop.Token);
                        if (read == 0) break;
                        request.Write(buffer, 0, read);
                        var text = Encoding.ASCII.GetString(request.GetBuffer(),
                            0, (int)request.Length);
                        if (text.Contains("\r\n\r\n")) break;
                    }
                    var head = Encoding.ASCII.GetString(request.GetBuffer(),
                        0, (int)request.Length);
                    var line = head.Split("\r\n")[0];
                    var parts = line.Split(' ');
                    if (parts.Length < 2) return;
                    var path = parts[1].Split('?')[0];
                    Interlocked.Increment(ref _count);
                    lock (_lock) _paths.Add(path);
                    if (!_routes.TryGetValue(path, out var route))
                    {
                        await WriteResponse(stream, 404, Encoding.UTF8.GetBytes("missing"),
                            null);
                        return;
                    }
                    await WriteResponse(stream, route.Status, route.Body, route);
                }
                catch (IOException) { }
                catch (OperationCanceledException) { }
            }
        }

        private async Task WriteResponse(NetworkStream stream, int status, byte[] body,
            Route? route)
        {
            var header = $"HTTP/1.1 {status} {(status == 200 ? "OK" : "Error")}\r\n" +
                         $"Content-Length: {body.Length}\r\n" +
                         "Connection: close\r\nContent-Type: application/octet-stream\r\n\r\n";
            var headerBytes = Encoding.ASCII.GetBytes(header);
            await stream.WriteAsync(headerBytes, _stop.Token);
            if (route?.DropAfter is { } drop)
            {
                await stream.WriteAsync(body.AsMemory(0, Math.Min(drop, body.Length)),
                    _stop.Token);
                return;
            }
            if (route is null || route.DelayMilliseconds <= 0)
            {
                await stream.WriteAsync(body, _stop.Token);
                return;
            }
            foreach (var value in body)
            {
                await Task.Delay(route.DelayMilliseconds, _stop.Token);
                await stream.WriteAsync(new[] { value }, _stop.Token);
            }
        }

        public void Dispose()
        {
            _stop.Cancel();
            _listener.Stop();
            _stop.Dispose();
        }
    }
}
