using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
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
                case "--hold-legacy-lock":
                {
                    // --hold-legacy-lock <root> <model> <sh|ex> <seconds>
                    var store = LegacyLeaseStore(args[1]);
                    using var lease = ModelLease.AcquireLegacy(store, args[2],
                        args[3] == "ex", TimeSpan.FromSeconds(10));
                    Console.WriteLine("locked");
                    Console.Out.Flush();
                    Thread.Sleep(TimeSpan.FromSeconds(double.Parse(args[4])));
                    Environment.Exit(0);
                    return;
                }
                case "--require-legacy":
                {
                    // --require-legacy <root> <model>
                    var store = LegacyLeaseStore(args[1]);
                    try
                    {
                        using var lease = ModelLease.AcquireLegacy(store, args[2], false,
                            TimeSpan.Zero);
                        var flat = Path.Combine(args[1], args[2], "payload.bin");
                        Console.WriteLine(File.Exists(flat) ? "loaded" : "missing");
                        Environment.Exit(File.Exists(flat) ? 0 : 4);
                    }
                    catch (ModelStoreError error) when (error.Code == "E_MODEL_LEASED")
                    {
                        Console.WriteLine("leased");
                        Environment.Exit(3);
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
        RunProgressIdentitySourceContract();
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
        RunLegacyLeases();
        RunProductionCatalog();
        RunRedirects();
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
        C(full.RootElement.GetProperty("entries").GetArrayLength() == 11,
            "full fixture lists the rejected cases");
        C(!tryLoadFull(server.Base), "a catalog with an insecure entry is rejected as a whole");
        foreach (var id in new[]
                 {
                     "fixture-http", "fixture-offhost", "fixture-traversal",
                     "fixture-file-port", "fixture-file-scheme",
                     "fixture-file-userinfo", "fixture-file-fragment",
                 })
            C(!TryLoadSingle(id, server.Base), $"{id} is rejected at catalog load");
        C(!TryLoadSingle("fixture-file-port", server.Base, allowLocalHttp: false),
            "a non-default file port is refused in production");
        C(!TryLoadSingle("fixture-good", server.Base, allowLocalHttp: false),
            "production refuses the loopback HTTP test source");
        C(TryLoadSingle("fixture-good", server.Base, allowLocalHttp: true),
            "the explicit test opt-in accepts loopback HTTP");
        C(TryLoadSingle("fixture-good", "https://example.com", allowLocalHttp: false),
            "a default-port HTTPS source loads in production");
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

    private static void RunProgressIdentitySourceContract()
    {
        Console.WriteLine("[M6b] cancelled progress cannot reach a retry (source contract)");
        var store = File.ReadAllText(Path.Combine(RepositoryRoot, "Windows",
            "RetouchStudio.AI", "Models", "ModelStore.cs")).ReplaceLineEndings("\n");
        var window = File.ReadAllText(Path.Combine(RepositoryRoot, "Windows",
            "RetouchStudio.App", "ModelManagerWindow.xaml.cs")).ReplaceLineEndings("\n");

        C(store.Contains("value => ReportProgress(progress, cancellationToken, value)",
            StringComparison.Ordinal) &&
          store.Contains("ReportProgress(progress, cancellationToken, new ModelTransferProgress",
            StringComparison.Ordinal),
          "install and adoption both report through the cancellation-aware transfer boundary");
        C(store.Contains("if (!cancellationToken.IsCancellationRequested)\n" +
                        "            progress?.Report(value);", StringComparison.Ordinal),
          "the store does not publish a callback after its transfer is cancelled");
        C(window.Contains("var generation = ++_transferGeneration;", StringComparison.Ordinal) &&
          window.Contains("_activeTransferGeneration = generation;", StringComparison.Ordinal) &&
          window.Contains("TransferProgress(entry, generation)", StringComparison.Ordinal),
          "each retry receives a new active UI generation");

        var progressStart = window.IndexOf(
            "private IProgress<ModelTransferProgress> TransferProgress", StringComparison.Ordinal);
        var progressSource = progressStart < 0 ? "" : window[progressStart..];
        var guard = progressSource.IndexOf(
            "if (generation != _activeTransferGeneration || !_busy) return;",
            StringComparison.Ordinal);
        var apply = progressSource.IndexOf("var total = update.TotalBytes", StringComparison.Ordinal);
        C(guard >= 0 && apply > guard,
          "a queued callback is rejected before it can touch the retry's progress UI");
        C(window.Contains("_activeTransferGeneration = 0;", StringComparison.Ordinal),
          "a completed transfer stops accepting queued callbacks");
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

    private static void RunLegacyLeases()
    {
        Console.WriteLine("[M18] legacy flat lease: adoption vs a live reader");
        using var server = new FixtureServer();
        server.Serve("/good/payload.bin", "fixture-one\n");
        var store = MakeStore(server);
        var entry = store.Catalog.Entry("fixture-good")!;
        var flat = store.Layout.ModelDirectory("fixture-good");
        Directory.CreateDirectory(flat);
        File.WriteAllText(Path.Combine(flat, "payload.bin"), "fixture-one\n");

        var (holder, holderLine) = LaunchLegacyHolder(store.Layout.Root, "fixture-good",
            false);
        C(holderLine == "locked", "a child holds the shared flat lease");
        ExpectCode(() => store.MigrateLegacyAsync(entry).GetAwaiter().GetResult(),
            "E_MODEL_LEASED", "adoption refuses while a reader holds the flat lease", C);
        C(File.Exists(Path.Combine(flat, "payload.bin")),
            "a refused adoption leaves the flat file intact");
        C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
            "a refused adoption publishes no version");
        Stop(holder);
        holder.WaitForExit();
        Thread.Sleep(150);
        store.MigrateLegacyAsync(entry).GetAwaiter().GetResult();
        C(store.ActivePointer("fixture-good")?.Version == "1.0.0",
            "adoption succeeds after the reader dies");
        C(!File.Exists(Path.Combine(flat, "payload.bin")),
            "the adopted file left the flat layout");

        var second = MakeStore(server);
        var secondEntry = second.Catalog.Entry("fixture-good")!;
        var secondFlat = second.Layout.ModelDirectory("fixture-good");
        Directory.CreateDirectory(secondFlat);
        File.WriteAllText(Path.Combine(secondFlat, "payload.bin"), "fixture-one\n");
        // Adoption holds the exclusive flat lease while the worker tries to load.
        using (var exclusive = ModelLease.AcquireLegacy(second, "fixture-good", true))
        {
            var (refused, refusedLine) = LaunchRequireLegacy(second.Layout.Root,
                "fixture-good");
            refused.WaitForExit();
            C(refusedLine == "leased",
                "the worker refuses while adoption holds the flat lease", refusedLine);
            C(File.Exists(Path.Combine(secondFlat, "payload.bin")),
                "the refused worker left the flat file intact");
        }
        var (allowed, allowedLine) = LaunchRequireLegacy(second.Layout.Root, "fixture-good");
        allowed.WaitForExit();
        C(allowedLine == "loaded",
            "the worker loads after adoption releases the flat lease", allowedLine);
        second.MigrateLegacyAsync(secondEntry).GetAwaiter().GetResult();
        C(second.ActivePointer("fixture-good")?.Version == "1.0.0",
            "adoption succeeds after the worker exits");
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
        C(catalog.Entry("migan")?.Supports("windows-x64") == false,
            "MI-GAN is not advertised on Windows");
        C(catalog.Entry("migan")?.Capabilities.SequenceEqual(new[] { "inpaint.spot" }) == true,
            "MI-GAN is advertised for spot healing only",
            string.Join(", ", catalog.Entry("migan")?.Capabilities ?? new List<string>()));
        C(catalog.Entries.All(e => e.LicenseEvidenceUrl.StartsWith("https://",
            StringComparison.OrdinalIgnoreCase)),
            "every shipped entry has an HTTPS licence evidence URL");
    }

    // MARK: Redirect policy (R1)

    /// <summary>
    /// The signed-query token every refusal check looks for. A message that carried
    /// it would hand out a credential, which is why the Windows client builds its
    /// text from a re-parsed URI's host and path and never from the raw header.
    /// Mirrors the macOS suite's marker of the same name.
    /// </summary>
    private const string SignedQueryMarker = "sig=xet-signed-token-must-not-appear";

    private static void RunRedirects()
    {
        Console.WriteLine("[M19] redirects follow the catalog's host-and-path-class allow-list only");

        // Case 1 — an admitted 302 to another path class downloads the redirected
        // body, reaches the file, and records the origin plus the hop as host/path
        // only. Also proves the audit callback really fires for an admitted hop.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/payload.bin", "fixture-one\n");
            server.Redirect("/redirect-signed/payload.bin",
                $"/allowed-dest/payload.bin?{SignedQueryMarker}", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            var hops = new List<ModelRedirectHop>();
            var destination = RedirectDestination(store);
            RunDownload(store, $"{server.Base}/redirect-signed/payload.bin", destination,
                RedirectFile(store), hops);
            C(File.Exists(destination) && File.ReadAllText(destination) == "fixture-one\n",
                "an allowed 302 downloads the redirected body",
                File.Exists(destination) ? File.ReadAllText(destination) : "(no file)");
            C(hops.Select(hop => hop.Path).SequenceEqual(
                    new[] { "/redirect-signed/payload.bin", "/allowed-dest/payload.bin" }),
                "the hop list records origin then destination",
                string.Join(" -> ", hops.Select(hop => hop.Display)));
            C(hops.Count > 0 && hops[0].StatusCode == 0 && hops.Count > 1 &&
              hops[1].StatusCode == 302,
                "the origin carries no status and the hop carries the redirect status",
                string.Join(",", hops.Select(hop => hop.StatusCode)));
            C(!hops.Any(hop => hop.Display.Contains(SignedQueryMarker)),
                "no recorded hop carries the signed query",
                string.Join(" ", hops.Select(hop => hop.Display)));
            C(server.Paths[^1] == "/allowed-dest/payload.bin",
                "the client followed the redirect to the second route",
                string.Join(" ", server.Paths));
        }

        // The full install path through the same rule, ending in a verified version.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/payload.bin", "fixture-one\n");
            server.Redirect("/good/payload.bin",
                $"/allowed-dest/payload.bin?{SignedQueryMarker}", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            var entry = store.Catalog.Entry("fixture-good")!;
            var hops = new List<ModelRedirectHop>();
            // The progress argument is explicit so the hop recorder below cannot be
            // taken for the IProgress overload.
            var state = store.InstallAsync(entry, null, hops.Add)
                .GetAwaiter().GetResult();
            C(state.Version == "1.0.0" && state.Active,
                "install reaches a version through a redirect");
            C(store.Verify(entry, "1.0.0", true).Ok,
                "the redirect-installed version verifies");
            C(store.ActivePointer("fixture-good")?.Version == "1.0.0",
                "the redirect-installed version is active");
            C(hops.Select(hop => hop.Path).SequenceEqual(
                    new[] { "/good/payload.bin", "/allowed-dest/payload.bin" }),
                "InstallAsync forwards the hop recorder it documents",
                string.Join(" -> ", hops.Select(hop => hop.Display)));
            C(!hops.Any(hop => hop.Display.Contains(SignedQueryMarker)),
                "and the install trail leaks nothing",
                string.Join(" ", hops.Select(hop => hop.Display)));
            C(!StagingDirs(store).Any(), "a redirect install leaves no staging tree");
        }

        // Case 2 — Hugging Face's same-host relative 307 changes the path class. A
        // host-only allow-list would still fail this, so it is asserted separately.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-relative/payload.bin", "fixture-one\n");
            server.Redirect("/config.json",
                $"/allowed-relative/payload.bin?{SignedQueryMarker}&etag=W/\"abc\"", status: 307);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-relative/"));
            var hops = new List<ModelRedirectHop>();
            var destination = RedirectDestination(store);
            RunDownload(store, $"{server.Base}/config.json", destination,
                RedirectFile(store), hops);
            C(File.Exists(destination) && File.ReadAllText(destination) == "fixture-one\n",
                "a relative 307 that changes path class is followed");
            C(hops.Count == 2 && hops[^1].Path == "/allowed-relative/payload.bin" &&
              hops[^1].Host == "127.0.0.1" && hops[^1].StatusCode == 307,
                "the relative Location resolved against the request URL",
                hops.LastOrDefault()?.Display ?? "(none)");
            C(!hops.Any(hop => hop.Display.Contains("etag") ||
                               hop.Display.Contains(SignedQueryMarker)),
                "neither the etag nor the signed query survives into the trail",
                string.Join(" ", hops.Select(hop => hop.Display)));

            // An at sign in a query is data, not URL authority. The redirect
            // gate must not reject a valid destination merely for containing it.
            server.Redirect("/at-query.json",
                "/allowed-relative/payload.bin?token=a@b", status: 302);
            var atHops = new List<ModelRedirectHop>();
            var atDestination = RedirectDestination(store);
            RunDownload(store, $"{server.Base}/at-query.json", atDestination,
                RedirectFile(store), atHops);
            C(File.Exists(atDestination) && File.ReadAllText(atDestination) == "fixture-one\n" &&
              atHops.Count == 2 && atHops[^1].Path == "/allowed-relative/payload.bin",
                "an admitted destination may carry an at sign in its query",
                atHops.LastOrDefault()?.Display ?? "(none)");

            // Dot segments are refused before URI resolution can erase them.
            // Relative Locations remain supported, but `..` cannot walk out of
            // the wire path the catalog admitted.
            server.Serve("/redirected/allowed-relative/payload.bin", "fixture-one\n");
            server.Redirect("/nested/start.json",
                "../redirected/allowed-relative/payload.bin", status: 307);
            var parentStore = MakeRedirectStore(server,
                Rule("127.0.0.1", "/redirected/allowed-relative/"));
            var parentHops = new List<ModelRedirectHop>();
            var parentBefore = server.Count;
            var parentError = Capture(() => RunDownload(parentStore,
                $"{server.Base}/nested/start.json", RedirectDestination(parentStore),
                RedirectFile(parentStore), parentHops));
            C(parentError?.Message.Contains("refused a redirect") == true,
                "a parent-relative dot segment is refused before normalization",
                parentError?.Message);
            C(server.Count == parentBefore + 1 && server.Paths[^1] == "/nested/start.json",
                "the normalized parent destination is never requested",
                string.Join(" ", server.Paths));
            C(parentHops.Count == 1,
                "a refused relative hop never reaches the audit trail",
                string.Join(" ", parentHops.Select(hop => hop.Display)));
        }

        // Case 4 — a listed host whose path sits outside every pathPrefix.
        {
            using var server = new FixtureServer();
            server.Serve("/unlisted/payload.bin", "fixture-one\n");
            server.Serve("/allowed-dest/payload.bin", "fixture-one\n");
            server.Redirect("/r/wrong-path",
                $"{server.Base}/unlisted/payload.bin?{SignedQueryMarker}", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            var error = Capture(() => RunDownload(store, $"{server.Base}/r/wrong-path",
                RedirectDestination(store), RedirectFile(store)));
            C(error?.Message.Contains("refused a redirect") == true &&
              error.Message.Contains("host and path") &&
              error.Message.Contains("/unlisted/payload.bin"),
                "a listed host with an unlisted path class is refused", error?.Message);
            // The Location carried the signed token, so the refusal text must not:
            // it names host and path of the destination only.
            C(!error!.Message.Contains(SignedQueryMarker) && !error.Message.Contains('?'),
                "the path-class refusal carries no query", error.Message);
            C(!error.Message.Contains($"{server.Base}/r/wrong-path"),
                "the refusal names the destination, not the origin", error.Message);

            // A prefix match is not enough when a client or server may normalize
            // the path. Refuse traversal and encoded separators before requesting
            // the destination; SHA-256 is a byte gate, not a destination policy.
            var unsafeDestinations = new[]
            {
                "/allowed-dest/../unlisted/payload.bin",
                "/allowed-dest/a/../payload.bin",
                "/allowed-dest/%2e%2e/unlisted/payload.bin",
                "/allowed-dest/.%2e/unlisted/payload.bin",
                "/allowed-dest/%2e./unlisted/payload.bin",
                "/allowed-dest/%252e%252e/unlisted/payload.bin",
                "/allowed-dest/a%2f..%2funlisted/payload.bin",
                "/allowed-dest/a%5c..%5cunlisted/payload.bin",
            };
            for (var index = 0; index < unsafeDestinations.Length; index++)
            {
                var destination = unsafeDestinations[index];
                var origin = $"/r/unsafe-path-{index}";
                server.Redirect(origin, $"{server.Base}{destination}?{SignedQueryMarker}",
                    status: 302);
                var before = server.Count;
                var unsafeError = Capture(() => RunDownload(store, $"{server.Base}{origin}",
                    RedirectDestination(store), RedirectFile(store)));
                C(unsafeError?.Message.Contains("refused a redirect") == true,
                    $"an unsafe redirect path is refused: {destination}", unsafeError?.Message);
                C(server.Count == before + 1 && server.Paths[^1] == origin,
                    $"the unsafe destination is never requested: {destination}",
                    string.Join(" ", server.Paths));
                C(unsafeError is not null && !unsafeError.Message.Contains(SignedQueryMarker),
                    $"the unsafe-path refusal carries no signed query: {destination}",
                    unsafeError?.Message);
            }
        }

        // Cases 3 and 5 — an off-list host, and the absent-key default. Both refuse
        // without ever requesting the disallowed body.
        {
            using var server = new FixtureServer();
            server.Serve("/unlisted/payload.bin", "fixture-one\n");
            server.Redirect("/r/off-list", $"{server.Base}/unlisted/payload.bin", status: 302);
            var empty = MakeRedirectStore(server);
            var emptyError = Capture(() => RunDownload(empty, $"{server.Base}/r/off-list",
                RedirectDestination(empty), RedirectFile(empty)));
            C(empty.Catalog.RedirectAllowList.Count == 0,
                "the fixture catalog with no rules has an empty allow-list",
                $"{empty.Catalog.RedirectAllowList.Count}");
            C(emptyError?.Message.Contains("refused a redirect") == true &&
              emptyError.Message.Contains("127.0.0.1") &&
              emptyError.Message.Contains("/unlisted/"),
                "with no rules at all a redirect is refused by host and path",
                emptyError?.Message);
            C(!server.Paths.Contains("/unlisted/payload.bin"),
                "the disallowed body was never requested", string.Join(" ", server.Paths));

            // The identical server answer, now admitted: proves the refusal above
            // came from the missing key and not from anything about the response.
            var listed = MakeRedirectStore(server, Rule("127.0.0.1", "/unlisted/"));
            var listedDestination = RedirectDestination(listed);
            RunDownload(listed, $"{server.Base}/r/off-list", listedDestination,
                RedirectFile(listed));
            C(File.Exists(listedDestination) &&
              File.ReadAllText(listedDestination) == "fixture-one\n",
                "the same redirect succeeds once the catalog lists it");
        }

        // An absolute Location to another host is refused by host, not mangled into
        // a path on the origin.
        {
            using var server = new FixtureServer();
            server.Redirect("/absolute-offsite", "http://elsewhere.example/x", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            var error = Capture(() => RunDownload(store, $"{server.Base}/absolute-offsite",
                RedirectDestination(store), RedirectFile(store)));
            C(error?.Message.Contains("refused a redirect") == true &&
              error.Message.Contains("elsewhere.example"),
                "an absolute Location to an unlisted host is refused by host",
                error?.Message);
            C(!error!.Message.Contains("127.0.0.1/x"),
                "the Location was not treated as a path on the origin", error.Message);
            // The refusal is host-shaped, so it must name the off-site destination,
            // never the loopback origin that produced it.
            C(!error.Message.Contains($"{server.Base}/absolute-offsite"),
                "an off-host refusal names the destination, not the origin", error.Message);
        }

        // Case 6 — the hop budget: three redirects are followed, a fourth is refused.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/payload.bin", "fixture-one\n");
            server.Serve("/hop1/payload.bin", "", status: 302,
                location: $"{server.Base}/hop2/payload.bin?{SignedQueryMarker}");
            server.Serve("/hop2/payload.bin", "", status: 302,
                location: $"{server.Base}/hop3/payload.bin?{SignedQueryMarker}");
            server.Serve("/hop3/payload.bin", "", status: 302,
                location: $"{server.Base}/hop4/payload.bin?{SignedQueryMarker}");
            // While hop4 still redirects, the fourth hop is over budget; below it
            // answers 200, so exactly three redirects complete. The Location keeps
            // the signed token so the budget refusal is proven leak-free too.
            server.Serve("/hop4/payload.bin", "", status: 302,
                location: $"{server.Base}/allowed-dest/payload.bin?{SignedQueryMarker}");
            var rules = new[] { Rule("127.0.0.1", "/hop"), Rule("127.0.0.1", "/allowed-dest/") };
            C(ModelStore.MaxRedirectHops == 3, "the budget is three hops on both platforms",
                $"{ModelStore.MaxRedirectHops}");

            var over = MakeRedirectStore(server, rules);
            var overError = Capture(() => RunDownload(over, $"{server.Base}/hop1/payload.bin",
                RedirectDestination(over), RedirectFile(over)));
            C(overError?.Message.Contains("refused a redirect") == true &&
              overError.Message.Contains("budget"),
                "a chain longer than three redirects is refused", overError?.Message);
            C(!overError!.Message.Contains('?'), "and the over-budget refusal carries no query",
                overError.Message);

            // Budget refusal precedes Location parsing on both hosts: a malformed
            // fourth hop is still a budget refusal, not a different failure class.
            server.Serve("/hop4/payload.bin", "", status: 302);
            var missingLocation = MakeRedirectStore(server, rules);
            var missingLocationError = Capture(() => RunDownload(missingLocation,
                $"{server.Base}/hop1/payload.bin", RedirectDestination(missingLocation),
                RedirectFile(missingLocation)));
            C(missingLocationError?.Message.Contains("budget") == true,
                "the redirect budget is checked before a fourth Location is parsed",
                missingLocationError?.Message);

            // The fourth answer is a 200, so exactly three redirects complete.
            server.Serve("/hop4/payload.bin", "fixture-one\n");
            var at = MakeRedirectStore(server, rules);
            var hops = new List<ModelRedirectHop>();
            var destination = RedirectDestination(at);
            RunDownload(at, $"{server.Base}/hop1/payload.bin", destination,
                RedirectFile(at), hops);
            C(File.Exists(destination) && File.ReadAllText(destination) == "fixture-one\n",
                "exactly three redirects are followed");
            C(hops.Count == 4 && hops[0].StatusCode == 0 &&
              hops.Skip(1).All(hop => hop.StatusCode == 302),
                "the trail holds the origin plus the three admitted hops",
                string.Join(" -> ", hops.Select(hop => $"{hop.StatusCode}:{hop.Display}")));
        }

        // Each hop is re-checked, so a chain cannot launder a disallowed destination.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/payload.bin", "fixture-one\n");
            server.Serve("/chain1/payload.bin", "", status: 302,
                location: $"{server.Base}/chain2/payload.bin?{SignedQueryMarker}");
            server.Serve("/chain2/payload.bin", "", status: 302,
                location: $"{server.Base}/unlisted/payload.bin?{SignedQueryMarker}");
            var store = MakeRedirectStore(server,
                Rule("127.0.0.1", "/chain2/"), Rule("127.0.0.1", "/allowed-dest/"));
            var hops = new List<ModelRedirectHop>();
            var error = Capture(() => RunDownload(store, $"{server.Base}/chain1/payload.bin",
                RedirectDestination(store), RedirectFile(store), hops));
            C(error?.Message.Contains("refused a redirect") == true,
                "a second hop to an unlisted path is refused", error?.Message);
            C(!error!.Message.Contains(SignedQueryMarker) && !error.Message.Contains('?'),
                "and the refusal of the laundered hop leaks no signed query",
                error.Message);
            C(hops.Count == 2 && hops[1].Path == "/chain2/payload.bin",
                "the admitted first hop was recorded before the second was refused",
                string.Join(" -> ", hops.Select(hop => hop.Display)));
            C(!server.Paths.Contains("/unlisted/payload.bin"),
                "the refused hop never asked for the unlisted body",
                string.Join(" ", server.Paths));
        }

        // Case 7 — a Location that is file:/ftp: or carries credentials is refused
        // by shape, and its credentials are never quoted.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/payload.bin", "fixture-one\n");
            server.Redirect("/r/file-scheme", "file:///etc/passwd", status: 302);
            server.Redirect("/r/ftp-scheme", "ftp://127.0.0.1:2121/allowed-dest/payload.bin",
                status: 302);
            server.Redirect("/r/userinfo",
                "http://user:pass@127.0.0.1/allowed-dest/payload.bin", status: 302);
            server.Redirect("/r/empty-host-userinfo",
                "http://redirect-user:redirect-secret@", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            // Each refusal gets its own destination path and hop list: the shapes are
            // refused before a byte is written, and shared state would let one failure
            // hide another's file. The hop lists stay empty on purpose — that is what
            // proves a refused Location never reaches the audit trail.
            var fileDestination = Path.Combine(store.Layout.Root, "file-scheme.bin");
            var ftpDestination = Path.Combine(store.Layout.Root, "ftp-scheme.bin");
            var userinfoDestination = Path.Combine(store.Layout.Root, "userinfo.bin");
            var emptyHostDestination = Path.Combine(store.Layout.Root, "empty-host.bin");
            var shapeHops = new List<ModelRedirectHop>();

            var fileError = Capture(() => RunDownload(store, $"{server.Base}/r/file-scheme",
                fileDestination, RedirectFile(store), shapeHops));
            C(fileError?.Message.Contains("refused a redirect") == true &&
              !File.Exists(fileDestination),
                "a file: Location is refused and writes nothing", fileError?.Message);
            C(fileError!.Message.Contains("/etc/passwd"),
                "the refusal still names the destination path", fileError.Message);
            C(shapeHops.Count > 0 && shapeHops[0].StatusCode == 0 &&
              shapeHops[0].Path == "/r/file-scheme",
                "a refused hop is audited as the origin only",
                string.Join(" ", shapeHops.Select(hop => hop.Display)));

            var ftpError = Capture(() => RunDownload(store, $"{server.Base}/r/ftp-scheme",
                ftpDestination, RedirectFile(store), shapeHops));
            C(ftpError?.Message.Contains("refused a redirect") == true &&
              ftpError.Message.Contains("127.0.0.1") &&
              ftpError.Message.Contains("/allowed-dest/payload.bin"),
                "an ftp: Location is refused and names only host and path", ftpError?.Message);
            C(!File.Exists(ftpDestination), "and it wrote nothing", ftpDestination);

            var userinfoError = Capture(() => RunDownload(store, $"{server.Base}/r/userinfo",
                userinfoDestination, RedirectFile(store), shapeHops));
            C(userinfoError?.Message.Contains("refused a redirect") == true,
                "a Location with credentials is refused", userinfoError?.Message);
            C(!userinfoError!.Message.Contains("user:pass") &&
              !userinfoError.Message.Contains("pass") &&
              !userinfoError.Message.Contains('@'),
                "and its credentials are not quoted", userinfoError.Message);
            C(!File.Exists(userinfoDestination), "and it wrote nothing", userinfoDestination);

            var emptyHostHops = new List<ModelRedirectHop>();
            var emptyHostBefore = server.Count;
            var emptyHostError = Capture(() => RunDownload(store,
                $"{server.Base}/r/empty-host-userinfo", emptyHostDestination,
                RedirectFile(store), emptyHostHops));
            C(emptyHostError is ModelStoreError { Code: "E_INVALID_INPUT" } &&
              emptyHostError.Message.Contains("refused a redirect") &&
              !emptyHostError.Message.Contains("redirect-user") &&
              !emptyHostError.Message.Contains("redirect-secret"),
                "an unreadable Location is a typed policy refusal and never echoes credentials",
                emptyHostError?.Message);
            C(!File.Exists(emptyHostDestination), "and it wrote nothing", emptyHostDestination);
            C(emptyHostHops.Count == 1 && emptyHostHops[0].StatusCode == 0 &&
              emptyHostHops[0].Path == "/r/empty-host-userinfo",
                "the unreadable Location records only the origin",
                string.Join(" ", emptyHostHops.Select(hop => $"{hop.StatusCode}:{hop.Display}")));
            C(server.Count == emptyHostBefore + 1 &&
              server.Paths[^1] == "/r/empty-host-userinfo",
                "the unreadable Location caused no destination request",
                string.Join(" ", server.Paths));

            // A readable URI with an empty userinfo is still credentials on the
            // wire. Refuse it before Uri can canonicalize the authority away.
            server.Redirect("/r/empty-valid-userinfo",
                "http://@127.0.0.1/allowed-dest/payload.bin", status: 302);
            var emptyValidDestination = Path.Combine(store.Layout.Root, "empty-valid.bin");
            var emptyValidHops = new List<ModelRedirectHop>();
            var emptyValidBefore = server.Count;
            var emptyValidError = Capture(() => RunDownload(store,
                $"{server.Base}/r/empty-valid-userinfo", emptyValidDestination,
                RedirectFile(store), emptyValidHops));
            C(emptyValidError is ModelStoreError { Code: "E_INVALID_INPUT" } &&
              emptyValidError.Message.Contains("refused a redirect"),
                "a valid-host empty userinfo is refused before canonicalization",
                emptyValidError?.Message);
            C(!File.Exists(emptyValidDestination), "the empty-userinfo refusal wrote nothing",
                emptyValidDestination);
            C(emptyValidHops.Count == 1 && emptyValidHops[0].StatusCode == 0,
                "the empty-userinfo refusal records only the origin",
                string.Join(" ", emptyValidHops.Select(hop => hop.Display)));
            C(server.Count == emptyValidBefore + 1 &&
              server.Paths[^1] == "/r/empty-valid-userinfo" &&
              !server.Paths.Contains("/allowed-dest/payload.bin"),
                "the empty-userinfo destination was never requested",
                string.Join(" ", server.Paths));
            C(shapeHops.Count == 3 && shapeHops.All(hop => hop.StatusCode == 0),
                "no earlier refused hop reached the audit trail",
                string.Join(" ", shapeHops.Select(hop => $"{hop.StatusCode}:{hop.Display}")));
        }

        // A Location that is absent or unreadable is refused, and the refusal text
        // still carries no query.
        {
            using var server = new FixtureServer();
            server.Serve("/no-location/payload.bin", "", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/no-location/"));
            var bareDestination = Path.Combine(store.Layout.Root, "no-location.bin");
            var hops = new List<ModelRedirectHop>();
            var error = Capture(() => RunDownload(store, $"{server.Base}/no-location/payload.bin",
                bareDestination, RedirectFile(store), hops));
            C(error?.Message.Contains("refused a redirect") == true &&
              error.Message.Contains("Location"),
                "a redirect with no usable Location is refused", error?.Message);
            C(!File.Exists(bareDestination),
                "the 302 body was never treated as the payload", bareDestination);
            C(hops.Count > 0 && hops[0].StatusCode == 0,
                "a Location-less redirect records only the origin",
                string.Join(" ", hops.Select(hop => hop.Display)));

            server.Redirect("/leaky", $"/unlisted/payload.bin?{SignedQueryMarker}",
                status: 302);
            var leakyDestination = Path.Combine(store.Layout.Root, "leaky.bin");
            var leakyHops = new List<ModelRedirectHop>();
            var leaky = Capture(() => RunDownload(store, $"{server.Base}/leaky",
                leakyDestination, RedirectFile(store), leakyHops));
            C(leaky?.Message.Contains("127.0.0.1") == true &&
              leaky.Message.Contains("/unlisted/payload.bin"),
                "the refusal names the destination host and path", leaky?.Message);
            C(!leaky!.Message.Contains(SignedQueryMarker) && !leaky.Message.Contains('?'),
                "and never the query string", leaky.Message);
            C(leakyHops.Count == 1,
                "a redirect refused outside its path class leaks nothing to the trail either",
                string.Join(" ", leakyHops.Select(hop => hop.Display)));
        }

        // Case 8 — a chain ending in a non-200 is refused as an invalid answer.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/missing.bin", "nope", status: 404);
            server.Redirect("/good/payload.bin", "/allowed-dest/missing.bin", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            var error = Capture(() => store.InstallAsync(store.Catalog.Entry("fixture-good")!)
                .GetAwaiter().GetResult());
            C(error?.Message.Contains("HTTP 404") == true,
                "a redirect ending in a non-200 is refused", error?.Message);
            C(!Directory.Exists(store.Layout.VersionDirectory("fixture-good", "1.0.0")),
                "the refused chain installed no version");
            C(!StagingDirs(store).Any(), "the refused chain left no staging tree");
        }

        // The redirect-status vocabulary is exact. Exercise 301/303/308 through
        // the real manual loop as well as the predicate-level tests.
        {
            using var server = new FixtureServer();
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            foreach (var status in new[] { 301, 303, 308 })
            {
                var origin = $"/status-{status}/payload.bin";
                var target = $"/allowed-dest/status-{status}/payload.bin";
                server.Serve(target, "fixture-one\n");
                server.Redirect(origin, $"{target}?{SignedQueryMarker}", status);
                var destination = RedirectDestination(store);
                var hops = new List<ModelRedirectHop>();
                var error = Capture(() => RunDownload(store, $"{server.Base}{origin}",
                    destination, RedirectFile(store), hops));
                C(error is null && File.Exists(destination) && hops.Count == 2 &&
                  hops[^1].StatusCode == status && hops[^1].Path == target,
                    $"HTTP {status} is admitted over the real transport",
                    error?.Message ?? string.Join(" -> ", hops.Select(hop => hop.Display)));
            }

            foreach (var status in new[] { 300, 304 })
            {
                var origin = $"/not-redirect-{status}/payload.bin";
                server.Serve(origin, "fixture-one\n", status: status);
                var destination = RedirectDestination(store);
                var hops = new List<ModelRedirectHop>();
                var before = server.Count;
                var error = Capture(() => RunDownload(store, $"{server.Base}{origin}",
                    destination, RedirectFile(store), hops));
                C(error is ModelStoreError { Code: "E_INVALID_INPUT" } &&
                  error.Message.Contains($"HTTP {status}", StringComparison.Ordinal),
                    $"HTTP {status} is refused as a non-200 answer", error?.Message);
                C(!File.Exists(destination),
                    $"HTTP {status} wrote no destination file", destination);
                C(server.Count == before + 1 && hops.Count == 1 && hops[0].StatusCode == 0,
                    $"HTTP {status} caused no redirect follow or admitted hop",
                    string.Join(" ", server.Paths));
            }

            foreach (var (label, location) in new[]
                     {
                         ("missing", (string?)null), ("empty", "")
                     })
            {
                var origin = $"/{label}-location/payload.bin";
                server.Serve(origin, "", status: 302, location: location);
                var destination = RedirectDestination(store);
                var hops = new List<ModelRedirectHop>();
                var before = server.Count;
                var error = Capture(() => RunDownload(store, $"{server.Base}{origin}",
                    destination, RedirectFile(store), hops));
                C(error is ModelStoreError { Code: "E_INVALID_INPUT" } &&
                  error.Message.Contains("refused a redirect", StringComparison.Ordinal) &&
                  error.Message.Contains("Location", StringComparison.Ordinal),
                    $"a {label} Location is a typed policy refusal", error?.Message);
                C(!File.Exists(destination),
                    $"the {label}-Location response wrote no destination", destination);
                C(server.Count == before + 1 && hops.Count == 1 && hops[0].StatusCode == 0,
                    $"the {label}-Location refusal audited only the origin",
                    string.Join(" ", server.Paths));
            }

            server.Redirect("/empty-fragment/payload.bin",
                "/allowed-dest/payload.bin#", status: 302);
            var fragmentDestination = RedirectDestination(store);
            var fragmentHops = new List<ModelRedirectHop>();
            var fragmentBefore = server.Count;
            var fragmentError = Capture(() => RunDownload(store,
                $"{server.Base}/empty-fragment/payload.bin", fragmentDestination,
                RedirectFile(store), fragmentHops));
            C(fragmentError is ModelStoreError { Code: "E_INVALID_INPUT" } &&
              fragmentError.Message.Contains("refused a redirect", StringComparison.Ordinal),
                "an empty redirect fragment is a typed policy refusal",
                fragmentError?.Message);
            C(!File.Exists(fragmentDestination),
                "the empty-fragment refusal wrote nothing", fragmentDestination);
            C(server.Count == fragmentBefore + 1 && fragmentHops.Count == 1 &&
              fragmentHops[0].StatusCode == 0,
                "the empty-fragment destination was never requested or audited",
                string.Join(" ", server.Paths));

            var percentTarget = "/allowed-dest/100%25/payload.bin";
            server.Serve(percentTarget, "fixture-one\n");
            server.Redirect("/stable-percent/payload.bin",
                $"{percentTarget}?{SignedQueryMarker}", status: 302);
            var percentDestination = RedirectDestination(store);
            var percentHops = new List<ModelRedirectHop>();
            var percentError = Capture(() => RunDownload(store,
                $"{server.Base}/stable-percent/payload.bin", percentDestination,
                RedirectFile(store), percentHops));
            C(percentError is null && File.Exists(percentDestination) &&
              server.Paths.LastOrDefault() == percentTarget &&
              percentHops.LastOrDefault()?.Path == percentTarget,
                "a stable %25 reaches the wire and the redacted audit unchanged",
                $"{server.Paths.LastOrDefault()} / {percentHops.LastOrDefault()?.Display}");

            // Windows exposes both raw Location values to the manual policy loop;
            // it must reject the response without following either destination.
            server.RepeatedLocations("/duplicate-location/payload.bin",
                $"/allowed-dest/one.bin?{SignedQueryMarker}",
                $"/allowed-dest/two.bin?{SignedQueryMarker}");
            var duplicateDestination = RedirectDestination(store);
            var duplicateHops = new List<ModelRedirectHop>();
            var duplicateBefore = server.Count;
            var duplicateError = Capture(() => RunDownload(store,
                $"{server.Base}/duplicate-location/payload.bin", duplicateDestination,
                RedirectFile(store), duplicateHops));
            C(duplicateError is ModelStoreError { Code: "E_INVALID_INPUT" } &&
              duplicateError.Message.Contains("refused a redirect", StringComparison.Ordinal) &&
              !duplicateError.Message.Contains(SignedQueryMarker, StringComparison.Ordinal),
                "repeated Location headers are a typed policy refusal and echo no query",
                duplicateError?.Message);
            C(!File.Exists(duplicateDestination),
                "the duplicate-Location response wrote nothing", duplicateDestination);
            C(server.Count == duplicateBefore + 1 && duplicateHops.Count == 1 &&
              duplicateHops[0].StatusCode == 0 &&
              server.Paths[^1] == "/duplicate-location/payload.bin" &&
              !server.Paths.Contains("/allowed-dest/one.bin") &&
              !server.Paths.Contains("/allowed-dest/two.bin"),
                "the duplicate-Location response made no destination request",
                string.Join(" ", server.Paths));
        }

        // Transport exceptions are outside redirect policy but can quote the
        // complete signed URL. The user-visible failure must not echo them.
        {
            using var server = new FixtureServer();
            var catalog = ModelCatalog.LoadJson(
                RedirectCatalogJson(new[] { Rule("127.0.0.1", "/allowed-dest/") }, server.Base),
                allowLocalHttp: true);
            var root = Path.Combine(Path.GetTempPath(), $"rsstore-{Guid.NewGuid():N}");
            Directory.CreateDirectory(root);
            var handler = new SignedUrlFailureHandler();
            var store = new ModelStore(root, catalog, "windows-x64", allowLocalHttp: true,
                handler: handler);
            var destination = Path.Combine(root, "transport-error.bin");
            var signedUrl = $"{server.Base}/good/payload.bin?{SignedQueryMarker}";
            var error = Capture(() => RunDownload(store, signedUrl, destination,
                RedirectFile(store)));
            C(handler.LastRequestUrl.Contains(SignedQueryMarker),
                "the transport seam received the complete signed source URL",
                handler.LastRequestUrl);
            C(error is ModelStoreError { Code: "E_INVALID_INPUT" },
                "a transport exception becomes a typed download failure", error?.Message);
            C(error?.Message.Contains(SignedQueryMarker) == false &&
              error.Message.Contains(signedUrl, StringComparison.Ordinal) == false &&
              !error.Message.Contains('?'),
                "a transport failure never echoes the complete signed source URL", error.Message);
            C(!File.Exists(destination),
                "the transport failure wrote no destination file", destination);
        }

        // Case 9 — integrity stays final after an admitted redirect.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/sha.bin", "different!\n");   // 11 bytes, wrong hash
            server.Serve("/allowed-dest/size.bin", "short\n");       // wrong size
            server.Redirect("/good/payload.bin", "/allowed-dest/sha.bin", status: 302);
            var shaStore = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            ExpectCode(() => shaStore.InstallAsync(shaStore.Catalog.Entry("fixture-sha")!)
                    .GetAwaiter().GetResult(),
                "E_MODEL_UNVERIFIED", "a redirect to mismatched bytes fails the pinned SHA-256",
                C);
            C(!Directory.Exists(shaStore.Layout.VersionDirectory("fixture-sha", "1.0.0")),
                "no version from a redirect with a SHA mismatch");

            server.Redirect("/good/payload.bin", "/allowed-dest/size.bin", status: 302);
            var sizeStore = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            ExpectCode(() => sizeStore.InstallAsync(sizeStore.Catalog.Entry("fixture-size")!)
                    .GetAwaiter().GetResult(),
                "E_MODEL_UNVERIFIED", "a redirect to a different length fails the declared size",
                C);
            C(!StagingDirs(sizeStore).Any(), "an integrity failure leaves no staging tree");
        }

        // A successful HTTP status is not proof of a usable payload: an empty final
        // response still fails the declared size and leaves no installed version.
        {
            using var server = new FixtureServer();
            server.Serve("/allowed-dest/empty.bin", "", status: 200);
            server.Redirect("/good/payload.bin", "/allowed-dest/empty.bin", status: 302);
            var store = MakeRedirectStore(server, Rule("127.0.0.1", "/allowed-dest/"));
            ExpectCode(() => store.InstallAsync(store.Catalog.Entry("fixture-size")!)
                    .GetAwaiter().GetResult(),
                "E_MODEL_UNVERIFIED", "an empty final 200 fails the declared size", C);
            C(!Directory.Exists(store.Layout.VersionDirectory("fixture-size", "1.0.0")),
                "an empty final 200 installed no version");
            C(!StagingDirs(store).Any(), "an empty final 200 left no staging tree");
        }

        // The production API cannot accept an arbitrary HttpClient that follows
        // redirects before policy sees them. The internal test seam rejects known
        // auto-redirecting handlers, and a relative Location uses the response's
        // actual request URL rather than the loop's previous URI.
        {
            using var server = new FixtureServer();
            var catalog = ModelCatalog.LoadJson(RedirectCatalogJson(
                new[] { Rule("127.0.0.1", "/rewritten/nested/") }, server.Base),
                allowLocalHttp: true);
            var root = Path.Combine(Path.GetTempPath(), $"rsstore-{Guid.NewGuid():N}");
            Directory.CreateDirectory(root);
            var autoError = Capture(() => _ = new ModelStore(root, catalog, "windows-x64",
                allowLocalHttp: true, handler: new SocketsHttpHandler
                {
                    AllowAutoRedirect = true,
                }));
            C(autoError is ArgumentException,
                "the internal handler seam rejects an auto-redirecting sockets handler",
                autoError?.GetType().Name);
            var legacyAutoError = Capture(() => _ = new ModelStore(root, catalog, "windows-x64",
                allowLocalHttp: true, handler: new HttpClientHandler
                {
                    AllowAutoRedirect = true,
                }));
            C(legacyAutoError is ArgumentException,
                "the internal handler seam rejects an auto-redirecting legacy handler",
                legacyAutoError?.GetType().Name);
            C(typeof(ModelStore).GetConstructors().All(constructor => constructor
                    .GetParameters().All(parameter => parameter.ParameterType != typeof(HttpClient))),
                "no public constructor accepts an arbitrary HttpClient");

            var handler = new ResponseBaseHandler();
            var store = new ModelStore(root, catalog, "windows-x64", allowLocalHttp: true,
                handler: handler);
            var hops = new List<ModelRedirectHop>();
            var destination = RedirectDestination(store);
            RunDownload(store, $"{server.Base}/original/nested/start.json", destination,
                RedirectFile(store), hops);
            C(handler.Requests.Count == 2 &&
              handler.Requests[1].AbsolutePath == "/rewritten/nested/dest/payload.bin",
                "a relative Location resolves against response.RequestMessage.RequestUri",
                string.Join(" -> ", handler.Requests.Select(request => request.AbsolutePath)));
            C(File.Exists(destination) && File.ReadAllText(destination) == "fixture-one\n",
                "the response-base redirect reaches the real payload bytes");
            C(hops.Count == 2 && hops[1].Path == "/rewritten/nested/dest/payload.bin",
                "the response-base destination is audited without its query",
                string.Join(" -> ", hops.Select(hop => hop.Display)));
        }

        // The gates this change must not have widened: the recorded-source rule and
        // the shapes a rule may name.
        {
            var rules = new[]
            {
                Rule("huggingface.co", "/api/resolve-cache/"),
                Rule("us.aws.cdn.hf.co", "/xet-bridge-us/"),
            };
            Uri Url(string value) => new(value);
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://US.AWS.CDN.HF.CO/xet-bridge-us/repo/a"), rules) is not null,
                "the host comparison is case-insensitive");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://evil-us.aws.cdn.hf.co/xet-bridge-us/a"), rules) is null,
                "a suffix of an allowed host is not the allowed host");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://hf.co/xet-bridge-us/a"), rules) is null,
                "a prefix of an allowed host is not the allowed host");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://xet-bridge-us.aws.cdn.hf.co.attacker.example/a"), rules) is null,
                "a label-suffixed lookalike host is refused");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://us.aws.cdn.hf.co/other/a"), rules) is null,
                "an allowed host with an unlisted path class is refused");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us"), rules) is null,
                "the prefix must actually cover the path");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us/a"), Array.Empty<ModelRedirectRule>())
                is null, "an empty allow-list admits nothing");
            // The prefix is matched on the path the wire carries, so an encoded
            // delimiter cannot splice a second path class into an admitted one.
            // macOS has to agree with this pair: its URL exposes both a decoded and
            // an encoded path, and matching the decoded one would let
            // `/xet-bridge-us%2f…` through on one platform and refuse it here.
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us%2fapi/resolve-cache/x"),
                rules) is null,
                "an encoded slash cannot smuggle another class into an admitted one");
            foreach (var unsafePath in new[]
                     {
                         "/xet-bridge-us/../private/x",
                         "/xet-bridge-us/%2e%2e/x",
                         "/xet-bridge-us/.%2e/x",
                         "/xet-bridge-us/%2e./x",
                         "/xet-bridge-us/%252e%252e/x",
                         "/xet-bridge-us/a%2f..%2fprivate/x",
                         "/xet-bridge-us/a%5c..%5cprivate/x",
                         "/xet-bridge-us/%2fprivate/x",
                     })
                C(ModelCatalogRules.RedirectRuleMatching(
                    Url($"https://us.aws.cdn.hf.co{unsafePath}"), rules) is null,
                    $"a redirect path with traversal or an encoded separator is refused: {unsafePath}");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us/repo/a"), rules) is not null,
                "an ordinary path inside the admitted class still matches");
            C(ModelCatalogRules.RedirectRuleMatching(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us/repo/100%25/file"), rules) is not null,
                "a stable encoded percent sign remains an ordinary path");
            C(ModelCatalogRules.IsSafeRawRedirectPath(
                "https://us.aws.cdn.hf.co/xet-bridge-us/repo/100%25/file?token=a@b"),
                "raw absolute Location paths preserve stable percent escapes");
            C(ModelCatalogRules.IsSafeRawRedirectPath(
                "../xet-bridge-us/repo/file") == false,
                "a raw parent-relative Location is unsafe before URI normalization");
            C(ModelCatalogRules.IsSafeRawRedirectPath(
                "https://us.aws.cdn.hf.co/xet-bridge-us/a/../payload.bin") == false,
                "a raw absolute Location cannot hide traversal behind normalization");
            C(ModelCatalogRules.IsSafeRawRedirectLocation(
                "https://@us.aws.cdn.hf.co/xet-bridge-us/repo/file") == false,
                "a raw empty userinfo is refused before URI canonicalization");
            C(ModelCatalogRules.IsSafeRawRedirectLocation(
                "https://us.aws.cdn.hf.co/xet-bridge-us/repo/file?token=a@b"),
                "a raw at sign in the query is not authority userinfo");
            C(ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us/a"), allowLocalHttp: false),
                "an HTTPS default-port target has an allowed shape");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("http://us.aws.cdn.hf.co/xet-bridge-us/a"), allowLocalHttp: false),
                "plain HTTP is refused outside the test opt-in");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://us.aws.cdn.hf.co:8443/xet-bridge-us/a"), allowLocalHttp: false),
                "a non-default port is refused");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://paid:secret@us.aws.cdn.hf.co/xet-bridge-us/a"),
                allowLocalHttp: false), "userinfo is refused");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://@us.aws.cdn.hf.co/xet-bridge-us/a"),
                allowLocalHttp: false), "an empty userinfo authority is refused");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us/a#"),
                allowLocalHttp: false), "even an empty fragment is refused");
            C(ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://us.aws.cdn.hf.co/xet-bridge-us/repo/@scope/file?token=a@b"),
                allowLocalHttp: false), "an at sign in the path or query is not userinfo");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(Url("file:///etc/passwd"),
                allowLocalHttp: false), "a file: target has no allowed shape");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("ftp://us.aws.cdn.hf.co/xet-bridge-us/a"), allowLocalHttp: false),
                "an ftp: target has no allowed shape");
            C(ModelCatalogRules.IsAllowedRedirectTarget(
                Url("http://127.0.0.1:8080/allowed-dest/payload.bin"), allowLocalHttp: true),
                "the loopback-HTTP test allowance is unchanged, nothing more");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("https://127.0.0.1:8443/allowed-dest/payload.bin"), allowLocalHttp: true),
                "the loopback test opt-in does not widen HTTPS ports");
            C(!ModelCatalogRules.IsAllowedRedirectTarget(
                Url("http://example.com:8080/x"), allowLocalHttp: true),
                "the test opt-in never widens beyond loopback");
            C(ModelCatalogRules.IsRecordedFileSource("https://huggingface.co/a/b",
                    "https://huggingface.co/a", allowLocalHttp: false),
                "the recorded-source gate still accepts the recorded host");
            C(!ModelCatalogRules.IsRecordedFileSource(
                    "https://us.aws.cdn.hf.co/xet-bridge-us/a", "https://huggingface.co/a",
                    allowLocalHttp: false),
                "an allow-listed redirect host never becomes a recorded source");
            C(!ModelCatalogRules.IsRecordedFileSource("https://@huggingface.co/a/b",
                    "https://huggingface.co/a", allowLocalHttp: false),
                "a malformed empty userinfo cannot become a recorded source");

            // The load gate: an invalid rule fails the whole catalog with the same
            // unsafe class every other catalog defect uses, instead of being dropped.
            foreach (var (label, host, prefix) in new[]
                     {
                         ("a wildcard host", "*.hf.co", "/xet-bridge-us/"),
                         ("a host with a scheme", "https://us.aws.cdn.hf.co", "/xet-bridge-us/"),
                         ("a host with a port", "us.aws.cdn.hf.co:443", "/xet-bridge-us/"),
                         ("an uppercase host", "HuggingFace.CO", "/api/resolve-cache/"),
                         ("a path-less prefix", "huggingface.co", "api/resolve-cache/"),
                         ("a query in the prefix", "huggingface.co", "/api/resolve-cache/?t=1"),
                         ("a fragment in the prefix", "huggingface.co", "/api/resolve-cache/#x"),
                         ("a traversal in the prefix", "huggingface.co", "/api/../private/"),
                         ("a backslash in the prefix", "huggingface.co", "/api\\resolve-cache/"),
                         ("whitespace in the prefix", "huggingface.co", "/api/resolve cache/"),
                         ("an empty prefix", "huggingface.co", ""),
                         ("an empty host", "", "/api/resolve-cache/"),
                     })
            {
                ModelStoreError? failure = null;
                try { _ = RedirectCatalog(new[] { Rule(host, prefix) }, out _); }
                catch (ModelStoreError error) { failure = error; }
                C(failure is not null &&
                  failure.Message.Contains("unsafe", StringComparison.Ordinal),
                  $"the catalog refuses {label}",
                  failure?.Message ?? "accepted");
            }

            // An absent key decodes to no rules, and the shipped catalog states
            // exactly the two destinations that were measured.
            {
                var defaulted = RedirectCatalog(null, out var withoutKey);
                C(defaulted.RedirectAllowList.Count == 0,
                    "an absent redirectAllowList decodes to no rules — the safe default",
                    $"{defaulted.RedirectAllowList.Count}");
                C(withoutKey.Contains("entries") && !withoutKey.Contains("redirectAllowList"),
                    "the fixture really dropped the key");
                var shipped = ModelCatalog.Load(
                    Path.Combine(RepositoryRoot, "Resources", "model-catalog.json"));
                C(string.Join(",", shipped.RedirectAllowList.Select(r => r.Host)) ==
                    "huggingface.co,us.aws.cdn.hf.co",
                  "the shipped catalog lists the two measured hosts",
                  string.Join(" ", shipped.RedirectAllowList.Select(r => r.Host)));
                C(string.Join(",", shipped.RedirectAllowList.Select(r => r.PathPrefix)) ==
                    "/api/resolve-cache/,/xet-bridge-us/",
                  "and their measured path classes",
                  string.Join(" ", shipped.RedirectAllowList.Select(r => r.PathPrefix)));
                C(!shipped.RedirectAllowList.Any(r => r.Host == "cdn-lfs.hf.co"),
                    "no unmeasured host was added on assumption");
            }
        }
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

    private static bool TryLoadSingle(string id, string baseUrl, bool allowLocalHttp = true)
    {
        try
        {
            var document = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(FixtureDirectory, "catalog-fixture.json"))).RootElement;
            var entries = document.GetProperty("entries").EnumerateArray()
                .Where(e => e.GetProperty("id").GetString() == id)
                .Select(e => e.GetRawText());
            var json = $$"""{"schema":"retouchstudio.model-catalog/1","catalogVersion":"fixture-1","entries":[{{string.Join(",", entries)}}]}""";
            _ = ModelCatalog.LoadJson(json.Replace("{base}", baseUrl), allowLocalHttp);
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

    /// <summary>
    /// One allow-list rule, built the way the catalog JSON builds it. Mirrors the
    /// macOS suite's `rule(_:_:)`.
    /// </summary>
    private static ModelRedirectRule Rule(string host, string pathPrefix) =>
        new() { Host = host, PathPrefix = pathPrefix };

    /// <summary>
    /// Catalog bytes for one fixture entry whose file lives at
    /// <c>{base}/good/payload.bin</c>, with the allow-list set exactly as asked. A
    /// null list drops the key entirely — the default that must reproduce the
    /// historical refuse-every-redirect behaviour. Passing a loopback rule through
    /// this text is also what proves the new catalog key really decodes.
    /// </summary>
    private static string RedirectCatalogJson(IEnumerable<ModelRedirectRule>? rules,
        string baseUrl)
    {
        var document = JsonDocument.Parse(File.ReadAllText(
            Path.Combine(FixtureDirectory, "catalog-fixture.json"))).RootElement;
        var entries = document.GetProperty("entries").EnumerateArray()
            .Where(e => new[] { "fixture-good", "fixture-sha", "fixture-size" }
                .Contains(e.GetProperty("id").GetString()))
            .Select(e => e.GetRawText());
        var root = new JsonObject
        {
            ["schema"] = document.GetProperty("schema").GetString(),
            ["catalogVersion"] = document.GetProperty("catalogVersion").GetString(),
            ["entries"] = new JsonArray(entries.Select(JsonNode.Parse).ToArray()),
        };
        if (rules is not null)
        {
            root["redirectAllowList"] = new JsonArray(rules.Select(rule => (JsonNode)
                new JsonObject { ["host"] = rule.Host, ["pathPrefix"] = rule.PathPrefix })
                .ToArray());
        }
        return root.ToJsonString().Replace("{base}", baseUrl);
    }

    /// <summary>
    /// The same JSON plus a store over it. <c>rules</c> omitted means the key is
    /// absent, which is the fail-closed default.
    /// </summary>
    private static ModelCatalog RedirectCatalog(ModelRedirectRule[]? rules, out string json)
    {
        using var server = new FixtureServer();
        json = RedirectCatalogJson(rules, server.Base);
        return ModelCatalog.LoadJson(json, allowLocalHttp: true);
    }

    private static ModelStore MakeRedirectStore(FixtureServer server,
        params ModelRedirectRule[] rules)
    {
        var catalog = ModelCatalog.LoadJson(
            RedirectCatalogJson(rules.Length == 0 ? null : rules, server.Base),
            allowLocalHttp: true);
        var root = Path.Combine(Path.GetTempPath(), $"rsstore-{Guid.NewGuid():N}");
        // DownloadAsync writes its destination directly, so the root has to exist
        // before a bare download runs. InstallAsync creates it itself.
        Directory.CreateDirectory(root);
        return new ModelStore(root, catalog, "windows-x64", allowLocalHttp: true);
    }

    /// <summary>The fixture payload path, so a download test needs no staging tree.</summary>
    private static string RedirectDestination(ModelStore store) =>
        Path.Combine(store.Layout.Root, $"redirect-payload-{Guid.NewGuid():N}.bin");

    private static ModelCatalogFile RedirectFile(ModelStore store) =>
        store.Catalog.Entry("fixture-good")!.Files[0];

    /// <summary>
    /// Drives one download through the same internal path <c>InstallAsync</c> uses,
    /// recording the hop list the audit trail carries. The mirror of the macOS
    /// <c>runRedirectDownload</c>.
    /// </summary>
    private static void RunDownload(ModelStore store, string url, string destination,
        ModelCatalogFile file, ICollection<ModelRedirectHop>? hops = null) =>
        store.DownloadAsync(url, destination, store.Catalog.Entry("fixture-good")!,
            file.SizeBytes ?? 12, file.Path, 1, 1, 0, _ => { },
            store.Catalog.RedirectAllowList,
            hops is null ? null : hop => hops.Add(hop), CancellationToken.None)
            .GetAwaiter().GetResult();

    /// <summary>Runs one action that must throw and hands back the failure.</summary>
    private static Exception? Capture(Action action)
    {
        try
        {
            action();
            return null;
        }
        catch (Exception error)
        {
            return error;
        }
    }

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

    private static (Process Process, string? Line) LaunchLegacyHolder(string root,
        string model, bool exclusive)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("--hold-legacy-lock");
        start.ArgumentList.Add(root);
        start.ArgumentList.Add(model);
        start.ArgumentList.Add(exclusive ? "ex" : "sh");
        start.ArgumentList.Add("60");
        var process = Process.Start(start)!;
        var line = process.StandardOutput.ReadLine();
        return (process, line);
    }

    private static (Process Process, string? Line) LaunchRequireLegacy(string root,
        string model)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.ArgumentList.Add("--require-legacy");
        start.ArgumentList.Add(root);
        start.ArgumentList.Add(model);
        var process = Process.Start(start)!;
        var line = process.StandardOutput.ReadLine();
        return (process, line);
    }

    private static ModelStore LegacyLeaseStore(string root) =>
        new(root, ModelCatalog.LoadJson(
                """{"schema":"retouchstudio.model-catalog/1","catalogVersion":"test","entries":[]}""",
                allowLocalHttp: true),
            "windows-x64", allowLocalHttp: true);

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
        int? DropAfter, string? Location = null, string[]? AdditionalLocations = null);

    private sealed class SyncProgress<T> : IProgress<T>
    {
        private readonly Action<T> _report;

        public SyncProgress(Action<T> report) => _report = report;

        public void Report(T value) => _report(value);
    }

    /// <summary>
    /// No network and no redirect behaviour of its own. The first response points
    /// at a request URI different from the loop's current URI, proving that a
    /// relative Location is based on the response rather than stale loop state.
    /// </summary>
    private sealed class SignedUrlFailureHandler : HttpMessageHandler
    {
        public string LastRequestUrl { get; private set; } = "";

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastRequestUrl = request.RequestUri!.ToString();
            throw new HttpRequestException($"transport exploded at {LastRequestUrl}");
        }
    }

    private sealed class ResponseBaseHandler : HttpMessageHandler
    {
        public List<Uri> Requests { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(request.RequestUri!);
            if (Requests.Count > 1)
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(Encoding.UTF8.GetBytes("fixture-one\n")),
                    RequestMessage = request,
                });

            var response = new HttpResponseMessage(HttpStatusCode.Found)
            {
                RequestMessage = new HttpRequestMessage(HttpMethod.Get,
                    new Uri(request.RequestUri!, "/rewritten/nested/start.json")),
            };
            response.Headers.TryAddWithoutValidation("Location", "dest/payload.bin?token=a@b");
            return Task.FromResult(response);
        }
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
            int? dropAfter = null, int status = 200, string? location = null,
            string[]? additionalLocations = null) =>
            _routes[path] = new Route(Encoding.UTF8.GetBytes(body), status,
                delayMilliseconds, dropAfter, location, additionalLocations);

        /// <summary>
        /// Serves a redirect: the caller's status plus a <c>Location</c>. The body
        /// is empty with <c>Content-Length: 0</c>, so nothing but the header answers
        /// a hop. Routing strips the query, which is why the signed token a Location
        /// carries can only be observed in the client's own text — exactly what the
        /// redirect tests need to prove never leaks.
        /// </summary>
        public void Redirect(string path, string location, int status = 302) =>
            _routes[path] = new Route(Array.Empty<byte>(), status, 0, null, location);

        public void RepeatedLocations(string path, params string[] locations) =>
            _routes[path] = new Route(Array.Empty<byte>(), 302, 0, null,
                locations.Length > 0 ? locations[0] : null,
                locations.Length > 1 ? locations.Skip(1).ToArray() : Array.Empty<string>());

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
            // 307/308 keep their method on both platforms; the label only has to be
            // a valid reason-phrase, and the body stays empty for every redirect.
            var reason = status switch
            {
                200 => "OK",
                301 => "Moved Permanently",
                302 => "Found",
                303 => "See Other",
                307 => "Temporary Redirect",
                308 => "Permanent Redirect",
                404 => "Not Found",
                _ => "Error",
            };
            var locations = "";
            if (route?.Location is not null)
                locations += $"Location: {route.Location}\r\n";
            if (route?.AdditionalLocations is { } additional)
                foreach (var target in additional)
                    locations += $"Location: {target}\r\n";
            var header = $"HTTP/1.1 {status} {reason}\r\n" +
                         $"Content-Length: {body.Length}\r\n" +
                         locations +
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
