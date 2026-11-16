using System.Text.Json;
using System.Text.Json.Serialization;

namespace RetouchStudio.AI.Models;

/// <summary>One file the catalog says must exist, byte-for-byte.</summary>
public sealed class ModelCatalogFile
{
    public string Path { get; set; } = "";
    public long? SizeBytes { get; set; }
    public string? Sha256 { get; set; }
    public string SourceUrl { get; set; } = "";

    [JsonIgnore]
    public bool IsVerifiable =>
        SizeBytes is long size && size > 0 && IsSha256(Sha256);

    public static bool IsSha256(string? value) =>
        value is { Length: 64 } && value.All(c =>
            c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F');
}

public sealed class ModelPreprocess
{
    public string Id { get; set; } = "";
    public string Version { get; set; } = "";
}

/// <summary>Everything the manager needs to show and install one version.</summary>
public sealed class ModelCatalogEntry
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public List<string> Capabilities { get; set; } = new();
    public string Version { get; set; } = "";
    public string Format { get; set; } = "";
    public List<ModelCatalogFile> Files { get; set; } = new();
    public long? SizeBytes { get; set; }
    public string? Sha256 { get; set; }
    public string SourceUrl { get; set; } = "";
    public string CodeLicense { get; set; } = "";
    public string WeightsLicense { get; set; } = "";
    public string LicenseEvidenceUrl { get; set; } = "";
    public List<string> Platforms { get; set; } = new();
    public string RequiredProvider { get; set; } = "";
    public string MinimumContractVersion { get; set; } = "";
    public ModelPreprocess Preprocess { get; set; } = new();
    public bool Deterministic { get; set; }
    public string Notes { get; set; } = "";
    public string? UnverifiableReason { get; set; }

    [JsonIgnore]
    public bool IsVerifiable =>
        UnverifiableReason is null && SizeBytes is long total && total > 0 &&
        ModelCatalogFile.IsSha256(Sha256) &&
        Files.Count > 0 && Files.All(f => f.IsVerifiable);

    [JsonIgnore]
    public string? VerificationProblem
    {
        get
        {
            if (UnverifiableReason is { Length: > 0 } reason) return reason;
            if (SizeBytes is not { } total || total <= 0)
                return "the total size is missing";
            if (!ModelCatalogFile.IsSha256(Sha256)) return "the manifest SHA-256 is missing";
            if (Files.Count == 0) return "the file list is empty";
            var bad = Files.FirstOrDefault(f => !f.IsVerifiable);
            if (bad is not null) return $"{bad.Path} has no exact size or SHA-256";
            return null;
        }
    }

    public bool Supports(string platform) =>
        Platforms.Any(value => string.Equals(value, platform,
            StringComparison.OrdinalIgnoreCase));
}

public sealed class ModelCatalog
{
    public const string SchemaName = "retouchstudio.model-catalog/1";

    public string Schema { get; set; } = "";
    public string CatalogVersion { get; set; } = "";
    public List<ModelCatalogEntry> Entries { get; set; } = new();

    public ModelCatalogEntry? Entry(string id) =>
        Entries.FirstOrDefault(e => e.Id == id);

    public static ModelCatalog Load(string path, bool allowLocalHttp = false)
    {
        if (!File.Exists(path))
            throw new ModelStoreError("E_MODEL_MISSING", "the model catalog is missing");
        return LoadJson(File.ReadAllText(path), allowLocalHttp);
    }

    public static ModelCatalog LoadJson(string json, bool allowLocalHttp = false)
    {
        try
        {
            var catalog = JsonSerializer.Deserialize<ModelCatalog>(
                json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? throw new ModelStoreError("E_INVALID_INPUT", "the model catalog is empty");
            if (catalog.Schema != SchemaName)
                throw new ModelStoreError("E_INVALID_INPUT",
                    $"unsupported catalog schema {catalog.Schema}");
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in catalog.Entries)
            {
                if (!seen.Add(entry.Id))
                    throw new ModelStoreError("E_INVALID_INPUT",
                        $"the catalog lists {entry.Id} twice");
                ModelCatalogRules.Validate(entry, allowLocalHttp);
            }
            return catalog;
        }
        catch (JsonException error)
        {
            throw new ModelStoreError("E_INVALID_INPUT",
                $"the model catalog is unreadable: {error.Message}");
        }
    }

    public static string Platform
    {
        get
        {
            var arch = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture;
            return arch == System.Runtime.InteropServices.Architecture.Arm64
                ? "windows-arm64"
                : "windows-x64";
        }
    }
}

public static class ModelCatalogRules
{
    public static void Validate(ModelCatalogEntry entry, bool allowLocalHttp)
    {
        RequireComponent(entry.Id, "model id");
        RequireComponent(entry.Version, "model version");
        if (string.IsNullOrWhiteSpace(entry.Name))
            throw Unsafe($"{entry.Id} has no display name");
        if (entry.Capabilities.Count == 0 ||
            entry.Capabilities.Any(c => !IsCapability(c)))
            throw Unsafe($"{entry.Id} has an invalid capability id");
        if (!IsAllowedSource(entry.SourceUrl, allowLocalHttp) ||
            !Uri.TryCreate(entry.SourceUrl, UriKind.Absolute, out var entryUri) ||
            string.IsNullOrEmpty(entryUri.Host))
            throw Unsafe($"{entry.Id} has a non-HTTPS source");
        foreach (var file in entry.Files)
        {
            RequireFileComponent(file.Path, entry.Id);
            if (!IsRecordedFileSource(file.SourceUrl, entry.SourceUrl, allowLocalHttp))
                throw Unsafe($"{entry.Id}/{file.Path} does not come from the recorded source");
        }
        if (entry.UnverifiableReason is null && entry.SizeBytes is { } total && total > 0 &&
            entry.Files.All(f => f.SizeBytes is not null) &&
            entry.Files.Sum(f => f.SizeBytes ?? 0) != total)
            throw Unsafe($"{entry.Id} total size does not match its files");
    }

    /// <summary>
    /// Production accepts HTTPS on its default port only. A test may opt into
    /// loopback HTTP; that exception also covers the ephemeral port a local
    /// fixture server listens on. A non-default port is never accepted in
    /// production, even on loopback.
    /// </summary>
    public static bool IsAllowedSource(string url, bool allowLocalHttp)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            string.IsNullOrEmpty(uri.Host) || uri.UserInfo.Length > 0 ||
            url.Contains('#'))
            return false;
        var https = uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase);
        var testHttp = allowLocalHttp &&
                       uri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase) &&
                       IsLoopback(uri);
        if (!https && !testHttp) return false;
        return IsAllowedPort(uri, allowLocalHttp);
    }

    public static bool IsAllowedPort(Uri uri, bool allowLocalHttp) =>
        uri.IsDefaultPort || (allowLocalHttp && IsLoopback(uri));

    /// <summary>
    /// A file must come from the entry's recorded source: same scheme, same
    /// host, and the same port rules.
    /// </summary>
    public static bool IsRecordedFileSource(string url, string entrySource,
        bool allowLocalHttp)
    {
        if (!IsAllowedSource(url, allowLocalHttp) ||
            !IsAllowedSource(entrySource, allowLocalHttp) ||
            !Uri.TryCreate(url, UriKind.Absolute, out var fileUri) ||
            !Uri.TryCreate(entrySource, UriKind.Absolute, out var recordedUri))
            return false;
        return string.Equals(fileUri.Scheme, recordedUri.Scheme,
                   StringComparison.OrdinalIgnoreCase) &&
               string.Equals(fileUri.Host, recordedUri.Host,
                   StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsLoopback(Uri uri) =>
        uri.Host.Equals("127.0.0.1", StringComparison.OrdinalIgnoreCase) ||
        uri.Host.Equals("localhost", StringComparison.OrdinalIgnoreCase);

    public static void RequireComponent(string value, string field)
    {
        if (string.IsNullOrEmpty(value) || value is "." or ".." ||
            value.Contains("..") || !value.All(IsComponentChar))
            throw Unsafe($"invalid {field} {value}");
    }

    public static void RequireFileComponent(string path, string model)
    {
        if (string.IsNullOrEmpty(path) || path.StartsWith('/') ||
            path.Contains('\\') || path.Contains(':'))
            throw Unsafe($"{model} has an unsafe file path");
        foreach (var part in path.Split('/'))
        {
            if (part.Length == 0 || part is "." or ".." ||
                !part.All(IsComponentChar))
                throw Unsafe($"{model} has an unsafe file path");
        }
    }

    private static bool IsComponentChar(char c) =>
        c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9'
            or '-' or '_' or '.';

    private static bool IsCapability(string value) =>
        value.Length > 0 && value.Length <= 64 &&
        value.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '.' or '-');

    private static ModelStoreError Unsafe(string detail) =>
        new("E_INVALID_INPUT", $"the model catalog is unsafe: {detail}");
}
