using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RetouchStudio.AI.Models;

public sealed class ModelStoreError : Exception
{
    public string Code { get; }

    public ModelStoreError(string code, string detail) : base(detail)
    {
        Code = code;
    }

    public static ModelStoreError Leased(string model, string version) =>
        new("E_MODEL_LEASED",
            $"{model} {version} is in use by a running job or another window");

    public static ModelStoreError Unverified(string detail) =>
        new("E_MODEL_UNVERIFIED", detail);

    public static ModelStoreError Missing(string detail) =>
        new("E_MODEL_MISSING", detail);

    public static ModelStoreError Invalid(string detail) =>
        new("E_INVALID_INPUT", detail);

    public static ModelStoreError Cancelled() =>
        new("E_CANCELLED", "the download was cancelled; nothing was installed");
}

public sealed class ModelManifestFile
{
    public string Path { get; set; } = "";
    public long SizeBytes { get; set; }
    public string Sha256 { get; set; } = "";
}

public sealed class ModelManifest
{
    public const string SchemaName = "retouchstudio.model-manifest/1";

    public string Schema { get; set; } = "";
    public string ModelId { get; set; } = "";
    public string Version { get; set; } = "";
    public string CatalogVersion { get; set; } = "";
    public string ManifestSha256 { get; set; } = "";
    public List<ModelManifestFile> Files { get; set; } = new();
    public double InstalledAt { get; set; }
}

public sealed class ModelActivePointer
{
    public const string SchemaName = "retouchstudio.model-active/1";

    public string Schema { get; set; } = "";
    public string ModelId { get; set; } = "";
    public string Version { get; set; } = "";
    public string ManifestSha256 { get; set; } = "";
    public double ActivatedAt { get; set; }
}

public sealed class ModelTransferProgress
{
    public string File { get; init; } = "";
    public long ReceivedBytes { get; init; }
    public long? TotalBytes { get; init; }
    public int FileIndex { get; init; }
    public int FileCount { get; init; }
}

/// <summary>
/// Where one downloaded file actually ended up after redirects. Only the host
/// and path are ever carried, because Hugging Face's XET <c>Location</c> contains
/// a signed query string: anything that prints a hop — the audit trail or a
/// refusal message — gets a value that cannot leak credentials. Mirrors the
/// macOS <c>ModelRedirectHop</c>.
/// </summary>
public sealed class ModelRedirectHop
{
    public int StatusCode { get; init; }
    public string Host { get; init; } = "";
    public string Path { get; init; } = "/";

    public string Display => Host + Path;

    public static ModelRedirectHop For(int statusCode, Uri uri) => new()
    {
        StatusCode = statusCode,
        Host = uri.Host,
        Path = string.IsNullOrEmpty(uri.AbsolutePath) ? "/" : uri.AbsolutePath,
    };
}

public sealed class ModelVerifyProblem
{
    public string File { get; init; } = "";
    public string Reason { get; init; } = "";
}

public sealed class ModelVerifyReport
{
    public string ModelId { get; init; } = "";
    public string Version { get; init; } = "";
    public int Checked { get; init; }
    public List<ModelVerifyProblem> Problems { get; init; } = new();
    public bool Ok => Problems.Count == 0;
}

public sealed class ModelVersionState
{
    public string Version { get; init; } = "";
    public bool Active { get; init; }
    public long InstalledBytes { get; init; }
    public bool ManifestOk { get; init; }
    public DateTime? InstalledAt { get; init; }
}

public enum ModelAvailability
{
    Ready,
    NotInstalled,
    UnsupportedPlatform,
    Unverifiable,
}

public sealed class ModelRecord
{
    public ModelCatalogEntry Entry { get; init; } = new();
    public List<ModelVersionState> Versions { get; init; } = new();
    public string? ActiveVersion { get; init; }
    public ModelAvailability Availability { get; init; }
    public string? UnverifiableReason { get; init; }
    public long InstalledBytes { get; init; }
    public string Id => Entry.Id;
    public string Name => Entry.Name;
    public bool IsVerifiable => Entry.IsVerifiable;
}

public sealed class ModelCleanupDecision
{
    public string Directory { get; init; } = "";
    public string Action { get; init; } = "";
    public string Reason { get; init; } = "";
}

public sealed class ModelStoreLayout
{
    public string Root { get; }

    public ModelStoreLayout(string root)
    {
        Root = System.IO.Path.GetFullPath(root);
    }

    public string Staging => System.IO.Path.Combine(Root, ".staging");
    public string Quarantine => System.IO.Path.Combine(Root, ".quarantine");
    public string Locks => System.IO.Path.Combine(Root, ".locks");
    public string InstallGate => System.IO.Path.Combine(Locks, "install");
    public string ModelDirectory(string id) => System.IO.Path.Combine(Root, id);
    public string VersionDirectory(string id, string version) =>
        System.IO.Path.Combine(ModelDirectory(id), version);
    public string ManifestPath(string id, string version) =>
        System.IO.Path.Combine(VersionDirectory(id, version), "manifest.json");
    public string ActivePath(string id) =>
        System.IO.Path.Combine(ModelDirectory(id), "active.json");
    public string LockPath(string id, string version) =>
        System.IO.Path.Combine(Locks, $"{id}-{version}");

    /// <summary>
    /// A flat install has no version, so it gets a distinct identity. `@`
    /// cannot appear in a model id or version, so this can never collide with
    /// a versioned lock.
    /// </summary>
    public string LegacyLockPath(string id) =>
        System.IO.Path.Combine(Locks, $"{id}@legacy");
}

/// <summary>
/// A lease is a share-mode handle on a lock file. Windows enforces it for the
/// life of the handle; the kernel closes it when the process dies. Exclusive
/// means delete/install, shared means a reader or the worker.
/// </summary>
public sealed class ModelLease : IDisposable
{
    private FileStream? _stream;

    private ModelLease(FileStream stream) => _stream = stream;

    public static ModelLease Acquire(ModelStore store, string model, string version,
        bool exclusive, TimeSpan? timeout = null)
    {
        ModelCatalogRules.RequireComponent(model, "model id");
        ModelCatalogRules.RequireComponent(version, "model version");
        return AcquireFile(store.Layout.LockPath(model, version), exclusive, timeout,
            () => ModelStoreError.Leased(model, version));
    }

    public static ModelLease AcquireInstallGate(ModelStore store, TimeSpan? timeout = null) =>
        AcquireFile(store.Layout.InstallGate, true, timeout,
            () => new ModelStoreError("E_MODEL_LEASED",
                "another model install is already running"));

    /// <summary>
    /// The worker takes this shared while it reads a flat install; adoption
    /// takes it exclusive before moving any file. Same file name on every host.
    /// </summary>
    public static ModelLease AcquireLegacy(ModelStore store, string model, bool exclusive,
        TimeSpan? timeout = null)
    {
        ModelCatalogRules.RequireComponent(model, "model id");
        return AcquireFile(store.Layout.LegacyLockPath(model), exclusive, timeout,
            () => new ModelStoreError("E_MODEL_LEASED",
                $"{model}'s flat installation is in use by a running job"));
    }

    private static ModelLease AcquireFile(string path, bool exclusive, TimeSpan? timeout,
        Func<ModelStoreError> busy)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        for (var attempt = 0; attempt < 50 && !File.Exists(path); attempt++)
        {
            try
            {
                using var created = new FileStream(path, FileMode.CreateNew,
                    FileAccess.Write, FileShare.ReadWrite, 1, FileOptions.None);
            }
            catch (IOException) { }
            if (!File.Exists(path)) Thread.Sleep(5);
        }
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.Zero);
        while (true)
        {
            try
            {
                var stream = exclusive
                    ? new FileStream(path, FileMode.Open, FileAccess.ReadWrite,
                        FileShare.None, 1, FileOptions.None)
                    : new FileStream(path, FileMode.Open, FileAccess.Read,
                        FileShare.Read, 1, FileOptions.None);
                return new ModelLease(stream);
            }
            catch (IOException)
            {
                if (DateTime.UtcNow >= deadline) throw busy();
                Thread.Sleep(25);
            }
            catch (UnauthorizedAccessException)
            {
                if (DateTime.UtcNow >= deadline) throw busy();
                Thread.Sleep(25);
            }
        }
    }

    public void Dispose()
    {
        _stream?.Dispose();
        _stream = null;
    }
}

/// <summary>
/// Per-user, versioned model store. New versions appear by one directory move;
/// <c>active.json</c> is replaced by one atomic file move. Downloads write only
/// under <c>.staging</c>, and every mutation takes an OS lease first.
/// </summary>
public sealed class ModelStore
{
    public static readonly TimeSpan DefaultGrace = TimeSpan.FromHours(24);
    public const long RequiredReserve = 32L * 1024 * 1024;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    private readonly HttpClient _http;

    public ModelStoreLayout Layout { get; }
    public ModelCatalog Catalog { get; }
    public string Platform { get; }
    public bool AllowLocalHttp { get; }

    public ModelStore(string root, ModelCatalog catalog, string? platform = null,
        bool allowLocalHttp = false)
        : this(root, catalog, platform, allowLocalHttp, handler: null)
    {
    }

    /// <summary>
    /// Test-only transport seam. Production callers cannot inject an HttpClient
    /// that follows redirects before the catalog policy sees them; known handlers
    /// that automatically redirect or decompress are rejected here as well.
    /// </summary>
    internal ModelStore(string root, ModelCatalog catalog, string? platform,
        bool allowLocalHttp, HttpMessageHandler? handler)
    {
        Layout = new ModelStoreLayout(root);
        Catalog = catalog;
        Platform = platform ?? ModelCatalog.Platform;
        AllowLocalHttp = allowLocalHttp;
        _http = CreateHttpClient(handler);
    }

    private static HttpClient CreateHttpClient(HttpMessageHandler? handler)
    {
        handler ??= new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            ConnectTimeout = TimeSpan.FromSeconds(30),
        };
        if (handler is SocketsHttpHandler sockets &&
            (sockets.AllowAutoRedirect || sockets.AutomaticDecompression != DecompressionMethods.None))
            throw new ArgumentException("the model transport must not redirect or decompress",
                nameof(handler));
        if (handler is HttpClientHandler legacy &&
            (legacy.AllowAutoRedirect || legacy.AutomaticDecompression != DecompressionMethods.None))
            throw new ArgumentException("the model transport must not redirect or decompress",
                nameof(handler));
        return new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public static ModelStore CreateProduction()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var root = Environment.GetEnvironmentVariable("RETOUCH_AI_MODELS")
            ?? System.IO.Path.Combine(local, "Retouch Studio", "AI", "models");
        var catalogPath = System.IO.Path.Combine(AppContext.BaseDirectory,
            "model-catalog.json");
        var catalog = ModelCatalog.Load(catalogPath);
        return new ModelStore(root, catalog);
    }

    // MARK: Snapshot

    public List<ModelRecord> Records()
    {
        var records = new List<ModelRecord>();
        foreach (var entry in Catalog.Entries)
        {
            var availability = ModelAvailability.Ready;
            if (!entry.Supports(Platform)) availability = ModelAvailability.UnsupportedPlatform;
            else if (entry.VerificationProblem is { } problem)
            {
                availability = ModelAvailability.Unverifiable;
            }
            var versions = InstalledVersions(entry);
            string? pointer = null;
            try { pointer = ActivePointer(entry.Id)?.Version; }
            catch (ModelStoreError) { }
            if (!versions.Any(v => v.Version == pointer)) pointer = null;
            records.Add(new ModelRecord
            {
                Entry = entry,
                Versions = versions,
                ActiveVersion = pointer,
                Availability = availability,
                UnverifiableReason = entry.VerificationProblem,
                InstalledBytes = versions.Sum(v => v.InstalledBytes),
            });
        }
        return records;
    }

    public List<ModelVersionState> InstalledVersions(ModelCatalogEntry entry)
    {
        var modelDirectory = Layout.ModelDirectory(entry.Id);
        if (!Directory.Exists(modelDirectory)) return new List<ModelVersionState>();
        string? active = null;
        try { active = ActivePointer(entry.Id)?.Version; }
        catch (ModelStoreError) { }
        var result = new List<ModelVersionState>();
        foreach (var directory in Directory.EnumerateDirectories(modelDirectory))
        {
            var name = System.IO.Path.GetFileName(directory);
            if (name.StartsWith('.')) continue;
            ModelManifest? manifest = null;
            try { manifest = ReadManifest(directory); }
            catch (ModelStoreError) { }
            result.Add(new ModelVersionState
            {
                Version = name,
                Active = active == name,
                InstalledBytes = DirectorySize(directory),
                ManifestOk = manifest?.ModelId == entry.Id && manifest.Version == name,
                InstalledAt = manifest is null
                    ? null
                    : DateTimeOffset.FromUnixTimeMilliseconds(
                        (long)(manifest.InstalledAt * 1000)).LocalDateTime,
            });
        }
        return result
            .OrderByDescending(v => v.Version, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public ModelActivePointer? ActivePointer(string id)
    {
        var path = Layout.ActivePath(id);
        if (!File.Exists(path)) return null;
        try
        {
            var pointer = JsonSerializer.Deserialize<ModelActivePointer>(
                ReadSharedText(path), JsonOptions);
            if (pointer is null || pointer.Schema != ModelActivePointer.SchemaName ||
                pointer.ModelId != id)
                throw ModelStoreError.Unverified($"{id}'s active pointer is invalid");
            return pointer;
        }
        catch (JsonException)
        {
            throw ModelStoreError.Unverified($"{id}'s active pointer is invalid");
        }
    }

    public long DiskUsage() =>
        Catalog.Entries.Sum(e => InstalledVersions(e).Sum(v => v.InstalledBytes));

    public long? AvailableBytes()
    {
        try
        {
            var root = System.IO.Path.GetPathRoot(Layout.Root);
            return root is null ? null : new DriveInfo(root).AvailableFreeSpace;
        }
        catch (IOException)
        {
            return null;
        }
    }

    // MARK: Install

    public async Task<ModelVersionState> InstallAsync(ModelCatalogEntry entry,
        IProgress<ModelTransferProgress>? progress = null,
        CancellationToken cancellationToken = default) =>
        await InstallAsync(entry, progress, null, cancellationToken);

    /// <param name="redirectHops">
    /// Receives the origin and every admitted hop, for the audit trail and for the
    /// redirect tests. Only host and path ever reach it.
    /// </param>
    public async Task<ModelVersionState> InstallAsync(ModelCatalogEntry entry,
        IProgress<ModelTransferProgress>? progress,
        Action<ModelRedirectHop>? redirectHops,
        CancellationToken cancellationToken = default)
    {
        Validate(entry);
        PrepareLayout();
        if (!entry.Supports(Platform))
            throw ModelStoreError.Invalid($"{entry.Name} is not available on this platform");
        cancellationToken.ThrowIfCancellationRequested();

        using var gate = ModelLease.AcquireInstallGate(this);
        using var lease = ModelLease.Acquire(this, entry.Id, entry.Version, true);

        var versionDirectory = Layout.VersionDirectory(entry.Id, entry.Version);
        if (Directory.Exists(versionDirectory))
        {
            var existing = Verify(entry, entry.Version, true, lease);
            if (!existing.Ok)
                throw ModelStoreError.Unverified(
                    $"{entry.Id} {entry.Version} is installed but " +
                    $"{existing.Problems.FirstOrDefault()?.File ?? "its files"} failed verification");
            Activate(entry, entry.Version, lease);
            return VersionState(entry, entry.Version);
        }

        var total = entry.SizeBytes
            ?? throw ModelStoreError.Unverified(entry.VerificationProblem
                ?? "the total size is unknown");
        var available = AvailableBytes();
        if (available is { } free && free < total + RequiredReserve)
            throw ModelStoreError.Invalid(
                $"not enough disk space: {free} bytes available, {total} bytes needed plus a reserve");

        var staging = System.IO.Path.Combine(Layout.Staging, Guid.NewGuid().ToString("N"));
        CreatePrivateDirectory(staging);
        try
        {
            long received = 0;
            for (var index = 0; index < entry.Files.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var file = entry.Files[index];
                if (file.SizeBytes is not { } size || !ModelCatalogFile.IsSha256(file.Sha256))
                    throw ModelStoreError.Unverified(
                        $"{file.Path} has no exact size or SHA-256");
                var destination = System.IO.Path.Combine(staging,
                    file.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
                EnsureInside(staging, destination);
                CreatePrivateDirectory(System.IO.Path.GetDirectoryName(destination)!);
                var offset = received;
                var indexCopy = index;
                await DownloadAsync(file.SourceUrl, destination, entry, size,
                    file.Path, indexCopy + 1, entry.Files.Count, offset,
                    value => ReportProgress(progress, cancellationToken, value),
                    Catalog.RedirectAllowList, redirectHops, cancellationToken);
                var actualSize = new FileInfo(destination).Length;
                if (actualSize != size)
                    throw ModelStoreError.Unverified(
                        $"{file.Path} has {actualSize} bytes, expected {size}");
                var digest = await HashFileAsync(destination, cancellationToken);
                if (!string.Equals(digest, file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw ModelStoreError.Unverified($"{file.Path} failed its SHA-256 check");
                received += size;
            }

            var manifest = new ModelManifest
            {
                Schema = ModelManifest.SchemaName,
                ModelId = entry.Id,
                Version = entry.Version,
                CatalogVersion = Catalog.CatalogVersion,
                ManifestSha256 = entry.Sha256 ?? "",
                Files = entry.Files.Select(f => new ModelManifestFile
                {
                    Path = f.Path,
                    SizeBytes = f.SizeBytes ?? 0,
                    Sha256 = f.Sha256 ?? "",
                }).ToList(),
                InstalledAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            };
            WriteJson(manifest, System.IO.Path.Combine(staging, "manifest.json"), true);
            TestCrashPoint("after-verify");
            cancellationToken.ThrowIfCancellationRequested();

            var modelDirectory = Layout.ModelDirectory(entry.Id);
            EnsureRealDirectory(modelDirectory);
            Directory.Move(staging, versionDirectory);
            TestCrashPoint("after-rename");
        }
        catch (OperationCanceledException)
        {
            TryDelete(staging);
            throw ModelStoreError.Cancelled();
        }
        catch
        {
            TryDelete(staging);
            throw;
        }

        WritePointer(entry, entry.Version);
        return VersionState(entry, entry.Version);
    }

    /// <summary>
    /// The transfer's cancellation token is its identity at the reporting boundary.
    /// A callback that reaches this method after cancellation is stale and must not
    /// be queued into a progress sink that may already belong to a retry.
    /// </summary>
    private static void ReportProgress(IProgress<ModelTransferProgress>? progress,
        CancellationToken cancellationToken, ModelTransferProgress value)
    {
        if (!cancellationToken.IsCancellationRequested)
            progress?.Report(value);
    }

    /// <summary>
    /// Redirects one file may follow. Every hop is re-checked against the catalog's
    /// allow-list, so a longer chain cannot launder a disallowed destination.
    /// Same budget as the macOS delegate.
    /// </summary>
    public const int MaxRedirectHops = 3;

    private async Task DownloadAsync(string url, string destination, ModelCatalogEntry entry,
        long expectedSize, string relativePath, int index, int count, long offset,
        Action<ModelTransferProgress> report, CancellationToken cancellationToken) =>
        await DownloadAsync(url, destination, entry, expectedSize, relativePath, index, count,
            offset, report, Catalog.RedirectAllowList, null, cancellationToken);

    /// <summary>
    /// Fetches one recorded file, following only the redirects the catalog admits.
    /// <c>redirectAllowList</c> and <c>redirectHops</c> are the seams the tests use:
    /// a refusal can be exercised without rewriting the shared fixture, and the hop
    /// list is the audit trail. Integrity is unchanged and still final — declared
    /// size then pinned SHA-256, checked by the caller after this returns.
    /// </summary>
    internal async Task DownloadAsync(string url, string destination, ModelCatalogEntry entry,
        long expectedSize, string relativePath, int index, int count, long offset,
        Action<ModelTransferProgress> report, IReadOnlyList<ModelRedirectRule> redirectAllowList,
        Action<ModelRedirectHop>? redirectHops, CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            !ModelCatalogRules.IsRecordedFileSource(url, entry.SourceUrl, AllowLocalHttp))
            throw ModelStoreError.Invalid("refusing an unrecorded source");
        redirectHops?.Invoke(ModelRedirectHop.For(0, uri));
        var hops = 0;
        try
        {
            HttpResponseMessage response;
            while (true)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, uri);
                response = await _http.SendAsync(request,
                    HttpCompletionOption.ResponseHeadersRead, cancellationToken);
                if (!IsRedirectStatus(response.StatusCode)) break;
                // The handler answers 3xx itself (AllowAutoRedirect = false), so the
                // Location must be resolved here: HF sends relative ones. Disposal is
                // in finally so a refusal cannot leak the intermediate response.
                var statusCode = (int)response.StatusCode;
                var hopCount = ++hops;
                Uri? target = null;
                try
                {
                    // Match macOS: once the budget is exhausted, do not parse a new
                    // Location merely to discover that the hop is already forbidden.
                    if (hopCount <= MaxRedirectHops)
                        target = ResolveRedirectLocation(response);
                    RefuseRedirect(target, response.StatusCode, hopCount, redirectAllowList);
                }
                finally
                {
                    response.Dispose();
                }
                uri = target!;
                // The hop passed the rule, so it belongs in the audit trail: the
                // parameter promises the origin plus every admitted hop, which is
                // exactly what the macOS delegate reports through `onRedirect`.
                // Only host and path are carried — a signed query never leaves here.
                redirectHops?.Invoke(ModelRedirectHop.For(statusCode, uri));
            }
            using (response)
            {
                if (response.StatusCode != HttpStatusCode.OK)
                    throw ModelStoreError.Invalid(
                        $"the model source answered HTTP {(int)response.StatusCode}");
                await using var input =
                    await response.Content.ReadAsStreamAsync(cancellationToken);
                await using var output = new FileStream(destination, FileMode.CreateNew,
                    FileAccess.Write, FileShare.None, 1 << 20,
                    FileOptions.Asynchronous | FileOptions.WriteThrough);
                var buffer = new byte[1 << 20];
                long written = 0;
                while (true)
                {
                    var read = await input.ReadAsync(buffer, cancellationToken);
                    if (read == 0) break;
                    await output.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                    written += read;
                    report(new ModelTransferProgress
                    {
                        File = relativePath,
                        ReceivedBytes = offset + written,
                        TotalBytes = entry.SizeBytes,
                        FileIndex = index,
                        FileCount = count,
                    });
                }
                await output.FlushAsync(cancellationToken);
                output.Flush(true);
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            // HttpRequestException.Message can quote the complete request URL,
            // including signed query credentials. Preserve the typed failure, not
            // arbitrary exception text.
            _ = error;
            throw ModelStoreError.Invalid(
                "the download failed while contacting the recorded source");
        }
    }

    private static bool IsRedirectStatus(HttpStatusCode status) =>
        status is HttpStatusCode.Moved or HttpStatusCode.Found
            or HttpStatusCode.RedirectMethod or HttpStatusCode.TemporaryRedirect
            or HttpStatusCode.PermanentRedirect;

    /// <summary>
    /// Resolves exactly one raw <c>Location</c> against the request that produced
    /// the response. The raw path is checked before Uri can erase literal dot
    /// segments; absent, repeated, unreadable or unsafe values all fail closed.
    /// </summary>
    internal static Uri? ResolveRedirectLocation(HttpResponseMessage response)
    {
        if (!response.Headers.TryGetValues("Location", out var values)) return null;
        var locations = values.ToArray();
        if (locations.Length != 1) return null;
        var raw = locations[0].Trim();
        if (raw.Length == 0 || !ModelCatalogRules.IsSafeRawRedirectLocation(raw)) return null;
        if (response.RequestMessage?.RequestUri is not { IsAbsoluteUri: true } from) return null;
        return Uri.TryCreate(from, raw, out var absolute) && absolute.IsAbsoluteUri
            ? absolute
            : null;
    }

    /// <summary>
    /// The rule, identical to the macOS delegate: a redirect may be followed only
    /// when its status is a redirect, its Location resolves, the destination passes
    /// the shape rules the request URL already passed, the host matches one
    /// allow-list entry exactly and that entry's path prefix covers the path, all
    /// inside the hop budget. The refusal names host and path only — never the
    /// query, which on Hugging Face is a signed URL.
    /// </summary>
    private void RefuseRedirect(Uri? target, HttpStatusCode status, int hopCountUsed,
        IReadOnlyList<ModelRedirectRule> allowList)
    {
        var code = (int)status;
        if (hopCountUsed > MaxRedirectHops)
            throw ModelStoreError.Invalid(
                $"the download refused a redirect (exceeds the {MaxRedirectHops}-redirect budget)");
        if (target is null)
            throw ModelStoreError.Invalid(
                $"the download refused a redirect (HTTP {code} carried no usable Location)");
        if (!ModelCatalogRules.IsAllowedRedirectTarget(target, AllowLocalHttp))
            throw ModelStoreError.Invalid(
                $"the download refused a redirect (HTTP {code} to {HopDisplay(target)} leaves " +
                "the recorded source scheme, port or shape)");
        if (ModelCatalogRules.RedirectRuleMatching(target, allowList) is null)
            throw ModelStoreError.Invalid(
                $"the download refused a redirect (HTTP {code} to {HopDisplay(target)} is not " +
                "an allowed redirect host and path)");
        RedirectAudit(target, code);
    }

    /// <summary>Host and path of an admitted hop; the query is never carried.</summary>
    private static string HopDisplay(Uri uri) => ModelRedirectHop.For(0, uri).Display;

    private static void RedirectAudit(Uri uri, int statusCode)
    {
        Trace.WriteLine($"RetouchStudio model download redirect {statusCode} -> " +
                        HopDisplay(uri));
    }

    // MARK: Verify / activate / delete

    public ModelVerifyReport Verify(ModelCatalogEntry entry, string version, bool full,
        ModelLease? lease = null)
    {
        var owned = lease is null ? ModelLease.Acquire(this, entry.Id, version, false) : null;
        var held = lease ?? owned!;
        try
        {
            return VerifyLocked(entry, version, full);
        }
        finally
        {
            GC.KeepAlive(held);
            owned?.Dispose();
        }
    }

    private ModelVerifyReport VerifyLocked(ModelCatalogEntry entry, string version, bool full)
    {
        var directory = Layout.VersionDirectory(entry.Id, version);
        if (!Directory.Exists(directory))
            throw ModelStoreError.Missing($"{entry.Id} {version} is not installed");
        var problems = new List<ModelVerifyProblem>();
        ModelManifest manifest;
        try { manifest = ReadManifest(directory); }
        catch (ModelStoreError)
        {
            return new ModelVerifyReport
            {
                ModelId = entry.Id,
                Version = version,
                Problems =
                {
                    new ModelVerifyProblem
                        { File = "manifest.json", Reason = "missing or unreadable" },
                },
            };
        }
        if (manifest.ModelId != entry.Id || manifest.Version != version)
            problems.Add(new ModelVerifyProblem
                { File = "manifest.json", Reason = "identity mismatch" });
        if (manifest.ManifestSha256 != (entry.Sha256 ?? ""))
            problems.Add(new ModelVerifyProblem
                { File = "manifest.json", Reason = "catalog digest mismatch" });
        var recorded = manifest.Files.ToDictionary(f => f.Path, StringComparer.Ordinal);
        var expected = entry.Files.Select(f => f.Path).ToHashSet(StringComparer.Ordinal);
        if (!recorded.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(expected))
            problems.Add(new ModelVerifyProblem
                { File = "manifest.json", Reason = "file list mismatch" });

        var checkedFiles = 0;
        foreach (var file in entry.Files)
        {
            if (file.SizeBytes is not { } size || !ModelCatalogFile.IsSha256(file.Sha256))
            {
                problems.Add(new ModelVerifyProblem
                    { File = file.Path, Reason = "catalog metadata incomplete" });
                continue;
            }
            if (recorded.TryGetValue(file.Path, out var record) &&
                (record.SizeBytes != size || record.Sha256 != file.Sha256))
                problems.Add(new ModelVerifyProblem
                    { File = file.Path, Reason = "manifest metadata mismatch" });
            var target = System.IO.Path.Combine(directory,
                file.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
            if (!File.Exists(target))
            {
                problems.Add(new ModelVerifyProblem { File = file.Path, Reason = "missing" });
                continue;
            }
            if (new FileInfo(target).Length != size)
            {
                problems.Add(new ModelVerifyProblem { File = file.Path, Reason = "size" });
                continue;
            }
            if (full)
            {
                var digest = HashFile(target);
                if (!string.Equals(digest, file.Sha256, StringComparison.OrdinalIgnoreCase))
                    problems.Add(new ModelVerifyProblem { File = file.Path, Reason = "checksum" });
            }
            checkedFiles++;
        }
        return new ModelVerifyReport
        {
            ModelId = entry.Id,
            Version = version,
            Checked = checkedFiles,
            Problems = problems,
        };
    }

    public void Activate(ModelCatalogEntry entry, string version, ModelLease? lease = null)
    {
        var owned = lease is null ? ModelLease.Acquire(this, entry.Id, version, false) : null;
        var held = lease ?? owned!;
        try
        {
            var report = Verify(entry, version, true, held);
            if (!report.Ok)
                throw ModelStoreError.Unverified(
                    $"{entry.Id} {version} failed verification: " +
                    $"{report.Problems.FirstOrDefault()?.Reason ?? "unknown"}");
            WritePointer(entry, version);
        }
        finally
        {
            GC.KeepAlive(held);
            owned?.Dispose();
        }
    }

    public void Delete(ModelCatalogEntry entry, string version)
    {
        PrepareLayout();
        using var lease = ModelLease.Acquire(this, entry.Id, version, true);
        var directory = Layout.VersionDirectory(entry.Id, version);
        if (!Directory.Exists(directory))
            throw ModelStoreError.Missing($"{entry.Id} {version} is not installed");
        RemoveActivePointer(entry.Id, version);
        TestCrashPoint("after-pointer-removal");
        var quarantine = System.IO.Path.Combine(Layout.Quarantine,
            Guid.NewGuid().ToString("N"));
        Directory.Move(directory, quarantine);
        TryDelete(quarantine);
    }

    public void DeleteAll(ModelCatalogEntry entry)
    {
        PrepareLayout();
        var leases = new List<ModelLease>();
        try
        {
            var versions = InstalledVersions(entry);
            foreach (var version in versions)
                leases.Add(ModelLease.Acquire(this, entry.Id, version.Version, true));
            foreach (var version in versions)
            {
                var directory = Layout.VersionDirectory(entry.Id, version.Version);
                RemoveActivePointer(entry.Id, version.Version);
                var quarantine = System.IO.Path.Combine(Layout.Quarantine,
                    Guid.NewGuid().ToString("N"));
                Directory.Move(directory, quarantine);
                TryDelete(quarantine);
            }
        }
        finally
        {
            foreach (var lease in leases) lease.Dispose();
        }
    }

    private void RemoveActivePointer(string id, string version)
    {
        var path = Layout.ActivePath(id);
        ModelActivePointer? pointer = null;
        try { pointer = ActivePointer(id); }
        catch (ModelStoreError) { }
        if (pointer?.Version == version ||
            (pointer is null && File.Exists(path)))
            File.Delete(path);
    }

    // MARK: Legacy flat installs

    public long? LegacyBytes(ModelCatalogEntry entry)
    {
        if (InstalledVersions(entry).Count > 0) return null;
        var directory = Layout.ModelDirectory(entry.Id);
        long total = 0;
        foreach (var file in entry.Files)
        {
            var target = System.IO.Path.Combine(directory,
                file.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
            var info = new FileInfo(target);
            if (!info.Exists) return null;
            total += info.Length;
        }
        return total;
    }

    public async Task<ModelVersionState> MigrateLegacyAsync(ModelCatalogEntry entry,
        IProgress<ModelTransferProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        Validate(entry);
        PrepareLayout();
        if (LegacyBytes(entry) is null)
            throw ModelStoreError.Missing($"{entry.Id} has no flat installation to adopt");
        cancellationToken.ThrowIfCancellationRequested();
        using var gate = ModelLease.AcquireInstallGate(this);
        // The flat lease is what the worker holds while it reads this install.
        // It is taken before hashing and released only after the files moved or
        // were put back, so a reader never sees a half-moved tree.
        using var legacyLease = ModelLease.AcquireLegacy(this, entry.Id, true);
        using var lease = ModelLease.Acquire(this, entry.Id, entry.Version, true);
        var versionDirectory = Layout.VersionDirectory(entry.Id, entry.Version);
        if (Directory.Exists(versionDirectory))
            throw ModelStoreError.Invalid($"{entry.Id} {entry.Version} is already versioned");

        var directory = Layout.ModelDirectory(entry.Id);
        long received = 0;
        for (var index = 0; index < entry.Files.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var file = entry.Files[index];
            if (file.SizeBytes is not { } size || !ModelCatalogFile.IsSha256(file.Sha256))
                throw ModelStoreError.Unverified($"{file.Path} has no exact size or SHA-256");
            var source = System.IO.Path.Combine(directory,
                file.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
            var info = new FileInfo(source);
            if (!info.Exists || info.Length != size ||
                !string.Equals(await HashFileAsync(source, cancellationToken), file.Sha256,
                    StringComparison.OrdinalIgnoreCase))
                throw ModelStoreError.Unverified(
                    $"{file.Path} does not match the catalog; it is left where it is");
            received += size;
            ReportProgress(progress, cancellationToken, new ModelTransferProgress
            {
                File = file.Path, ReceivedBytes = received, TotalBytes = entry.SizeBytes,
                FileIndex = index + 1, FileCount = entry.Files.Count,
            });
        }

        var staging = System.IO.Path.Combine(Layout.Staging, Guid.NewGuid().ToString("N"));
        CreatePrivateDirectory(staging);
        var moved = new List<(string From, string To)>();
        try
        {
            foreach (var file in entry.Files)
            {
                var source = System.IO.Path.Combine(directory,
                    file.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
                var target = System.IO.Path.Combine(staging,
                    file.Path.Replace('/', System.IO.Path.DirectorySeparatorChar));
                CreatePrivateDirectory(System.IO.Path.GetDirectoryName(target)!);
                File.Move(source, target);
                moved.Add((source, target));
            }
            var manifest = new ModelManifest
            {
                Schema = ModelManifest.SchemaName,
                ModelId = entry.Id,
                Version = entry.Version,
                CatalogVersion = Catalog.CatalogVersion,
                ManifestSha256 = entry.Sha256 ?? "",
                Files = entry.Files.Select(f => new ModelManifestFile
                {
                    Path = f.Path,
                    SizeBytes = f.SizeBytes ?? 0,
                    Sha256 = f.Sha256 ?? "",
                }).ToList(),
                InstalledAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
            };
            WriteJson(manifest, System.IO.Path.Combine(staging, "manifest.json"), true);
            Directory.Move(staging, versionDirectory);
        }
        catch (OperationCanceledException)
        {
            RollBack(moved, staging);
            throw ModelStoreError.Cancelled();
        }
        catch
        {
            RollBack(moved, staging);
            throw;
        }
        // A pointer failure leaves a complete, inactive version; the next
        // install verifies it and repairs the pointer without a download.
        WritePointer(entry, entry.Version);
        RemoveEmptyDirectories(directory);
        return VersionState(entry, entry.Version);
    }

    private static void RollBack(List<(string From, string To)> moved, string staging)
    {
        foreach (var item in moved.AsEnumerable().Reverse())
        {
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(item.From)!);
                File.Move(item.To, item.From);
            }
            catch (IOException) { }
        }
        TryDelete(staging);
    }

    // MARK: Cleanup

    public List<ModelCleanupDecision> Cleanup(DateTime? now = null,
        TimeSpan? grace = null)
    {
        var decisions = new List<ModelCleanupDecision>();
        try { PrepareLayout(); }
        catch (ModelStoreError error)
        {
            decisions.Add(new ModelCleanupDecision
                { Directory = "store", Action = "keep", Reason = error.Message });
            return decisions;
        }
        var clock = now ?? DateTime.UtcNow;
        var limit = grace ?? DefaultGrace;
        foreach (var (parent, kind) in new[]
                 { (Layout.Staging, "staging"), (Layout.Quarantine, "quarantine") })
        {
            if (!Directory.Exists(parent)) continue;
            foreach (var child in Directory.EnumerateDirectories(parent))
            {
                var name = System.IO.Path.GetFileName(child);
                var age = clock - Directory.GetLastWriteTimeUtc(child);
                if (age < limit)
                {
                    decisions.Add(new ModelCleanupDecision
                        { Directory = $"{kind}/{name}", Action = "keep",
                          Reason = "younger than the grace period" });
                    continue;
                }
                ModelManifest? manifest;
                try { manifest = ReadManifest(child); }
                catch (ModelStoreError) { manifest = null; }
                if (manifest is null)
                {
                    if (kind == "staging")
                    {
                        try
                        {
                            using var gate = ModelLease.AcquireInstallGate(this);
                            TryDelete(child);
                            decisions.Add(new ModelCleanupDecision
                                { Directory = $"{kind}/{name}", Action = "removed",
                                  Reason = "stale staging with no manifest and no install running" });
                        }
                        catch (ModelStoreError)
                        {
                            decisions.Add(new ModelCleanupDecision
                                { Directory = $"{kind}/{name}", Action = "keep",
                                  Reason = "an install holds the install gate" });
                        }
                    }
                    else
                    {
                        decisions.Add(new ModelCleanupDecision
                            { Directory = $"{kind}/{name}", Action = "keep",
                              Reason = "identity is not readable" });
                    }
                    continue;
                }
                try
                {
                    using var lease = ModelLease.Acquire(this, manifest.ModelId,
                        manifest.Version, true);
                    TryDelete(child);
                    decisions.Add(new ModelCleanupDecision
                        { Directory = $"{kind}/{name}", Action = "removed",
                          Reason = "older than 24 hours and unlocked" });
                }
                catch (ModelStoreError)
                {
                    decisions.Add(new ModelCleanupDecision
                        { Directory = $"{kind}/{name}", Action = "keep",
                          Reason = "a live lease holds it" });
                }
            }
        }
        return decisions;
    }

    // MARK: Helpers

    public void Validate(ModelCatalogEntry entry)
    {
        try { ModelCatalogRules.Validate(entry, AllowLocalHttp); }
        catch (ModelStoreError error)
        {
            throw ModelStoreError.Invalid(error.Message);
        }
        if (entry.VerificationProblem is { } problem)
            throw ModelStoreError.Unverified(problem);
    }

    private void PrepareLayout()
    {
        EnsureRealDirectory(Layout.Root);
        foreach (var directory in new[] { Layout.Staging, Layout.Quarantine, Layout.Locks })
            EnsureRealDirectory(directory);
    }

    private static void EnsureRealDirectory(string path)
    {
        var info = new DirectoryInfo(path);
        if (info.Exists)
        {
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                throw ModelStoreError.Invalid(
                    $"{info.Name} is not a private directory");
            return;
        }
        Directory.CreateDirectory(path);
    }

    private static void CreatePrivateDirectory(string path)
    {
        var info = new DirectoryInfo(path);
        if (info.Exists)
        {
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                throw ModelStoreError.Invalid(
                    $"{info.Name} is not a private directory");
            return;
        }
        Directory.CreateDirectory(path);
    }

    private static void EnsureInside(string root, string target)
    {
        var prefix = System.IO.Path.GetFullPath(root)
            .TrimEnd(System.IO.Path.DirectorySeparatorChar) +
            System.IO.Path.DirectorySeparatorChar;
        if (!System.IO.Path.GetFullPath(target).StartsWith(prefix,
                StringComparison.OrdinalIgnoreCase))
            throw ModelStoreError.Invalid("a model file escaped its staging directory");
    }

    private void TestCrashPoint(string name)
    {
        // Test binaries set both variables; a normal app run never does.
        if (Environment.GetEnvironmentVariable("RETOUCH_MODEL_TESTING") == "1" &&
            Environment.GetEnvironmentVariable("RETOUCH_MODEL_TEST_CRASH") == name)
            Environment.Exit(86);
    }

    private ModelVersionState VersionState(ModelCatalogEntry entry, string version)
    {
        string? active = null;
        try { active = ActivePointer(entry.Id)?.Version; }
        catch (ModelStoreError) { }
        ModelManifest? manifest = null;
        try { manifest = ReadManifest(Layout.VersionDirectory(entry.Id, version)); }
        catch (ModelStoreError) { }
        return new ModelVersionState
        {
            Version = version,
            Active = active == version,
            InstalledBytes = DirectorySize(Layout.VersionDirectory(entry.Id, version)),
            ManifestOk = manifest?.ModelId == entry.Id && manifest.Version == version,
            InstalledAt = manifest is null
                ? null
                : DateTimeOffset.FromUnixTimeMilliseconds(
                    (long)(manifest.InstalledAt * 1000)).LocalDateTime,
        };
    }

    private ModelManifest ReadManifest(string directory)
    {
        var path = System.IO.Path.Combine(directory, "manifest.json");
        try
        {
            var manifest = JsonSerializer.Deserialize<ModelManifest>(
                ReadSharedText(path), JsonOptions);
            if (manifest is null || manifest.Schema != ModelManifest.SchemaName)
                throw ModelStoreError.Unverified("unrecognised version manifest");
            return manifest;
        }
        catch (Exception error) when (error is JsonException or IOException
                                          or UnauthorizedAccessException)
        {
            throw ModelStoreError.Unverified("missing or unreadable version manifest");
        }
    }

    private void WritePointer(ModelCatalogEntry entry, string version)
    {
        var pointer = new ModelActivePointer
        {
            Schema = ModelActivePointer.SchemaName,
            ModelId = entry.Id,
            Version = version,
            ManifestSha256 = entry.Sha256 ?? "",
            ActivatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0,
        };
        WriteJson(pointer, Layout.ActivePath(entry.Id), true);
    }

    /// <summary>
    /// Reads a file without blocking an atomic replace. A pointer reader that
    /// denied delete access would make the next activation fail with a sharing
    /// violation, which would turn an atomic pointer into a lock.
    /// </summary>
    private static string ReadSharedText(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private static void WriteJson<T>(T value, string path, bool durable)    {
        var directory = System.IO.Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temporary = System.IO.Path.Combine(directory,
            $".{System.IO.Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        var json = JsonSerializer.Serialize(value, JsonOptions);
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write,
                   FileShare.None, 4096, FileOptions.WriteThrough))
        {
            var bytes = Encoding.UTF8.GetBytes(json);
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(true);
        }
        Exception? last = null;
        for (var attempt = 0; attempt < 200; attempt++)
        {
            try
            {
                File.Move(temporary, path, true);
                last = null;
                break;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                last = error;
                Thread.Sleep(10);
            }
        }
        if (last is not null)
        {
            try { File.Delete(temporary); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            throw last;
        }
        if (!durable) return;
        // Flush(true) above is the durability point for the file. File.Move is
        // atomic on NTFS; the parent directory entry is durable once the move
        // returns.
    }

    private static string HashFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.Read, 1 << 20);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static async Task<string> HashFileAsync(string path,
        CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.Read, 1 << 20, FileOptions.Asynchronous);
        var digest = await SHA256.HashDataAsync(stream, cancellationToken);
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    private static long DirectorySize(string directory)
    {
        if (!Directory.Exists(directory)) return 0;
        long total = 0;
        foreach (var file in Directory.EnumerateFiles(directory, "*",
                     SearchOption.AllDirectories))
        {
            try { total += new FileInfo(file).Length; }
            catch (IOException) { }
        }
        return total;
    }

    private static void RemoveEmptyDirectories(string root)
    {
        if (!Directory.Exists(root)) return;
        foreach (var directory in Directory.EnumerateDirectories(root, "*",
                     SearchOption.AllDirectories)
                     .OrderByDescending(path => path.Length))
        {
            try
            {
                if (!Directory.EnumerateFileSystemEntries(directory).Any())
                    Directory.Delete(directory);
            }
            catch (IOException) { }
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, true);
            else if (File.Exists(path)) File.Delete(path);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
