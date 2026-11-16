using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RetouchStudio.AI;

/// <summary>
/// The schema-2 readiness record shared with macOS. The host writes it before
/// launch and the worker replaces it atomically while holding a lock, so a
/// reader never sees a torn record.
/// </summary>
public sealed class WorkerRegistry
{
    public const string FileName = "helper-registry.json";
    public const string LockFileName = "helper-registry.lock";
    public const int Schema = 2;

    private readonly string _path;
    private readonly string? _generation;
    private readonly string? _nonce;
    private readonly string _pipe;

    public WorkerRegistry(string path, string? generation, string? nonce, string pipe)
    {
        _path = Path.GetFullPath(path);
        _generation = generation;
        _nonce = nonce;
        _pipe = pipe;
    }

    public void Starting() => Write("starting", null);
    public void Ready() => Write("ready", null);
    public void Failed(string error) => Write("failed", error);

    private void Write(string state, string? error)
    {
        var directory = Path.GetDirectoryName(_path)
            ?? throw new InvalidOperationException("registry path has no directory");
        Directory.CreateDirectory(directory);

        var lockPath = Path.Combine(directory, LockFileName);
        if (File.Exists(lockPath) &&
            (File.GetAttributes(lockPath) & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException("the registry lock is a reparse point");
        }
        using var guard = new FileStream(lockPath, FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None);

        if (File.Exists(_path) &&
            (File.GetAttributes(_path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new IOException("the registry path is a reparse point");
        }

        var previous = ReadExisting();
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        var revision = state == "starting" ? 1 : 2;
        if (previous.TryGetPropertyValue("revision", out var priorRevision) &&
            priorRevision is not null)
        {
            revision = Math.Max(revision, priorRevision.GetValue<int>() + 1);
        }

        var existingParent = previous.TryGetPropertyValue("parent", out var parent)
            ? parent?.DeepClone() : null;
        var createdAt = previous.TryGetPropertyValue("created_at", out var created)
            ? created?.DeepClone() : JsonValue.Create(now);

        var record = new JsonObject
        {
            ["schema"] = Schema,
            ["protocol_version"] = Protocol.ProtocolVersion,
            ["generation"] = _generation,
            ["launch_nonce"] = _nonce,
            ["revision"] = revision,
            ["state"] = state,
            ["parent"] = existingParent,
            ["helper"] = Identity(Environment.ProcessId, ProcessIdentity.Start(Environment.ProcessId),
                Environment.ProcessPath),
            ["socket"] = _pipe,
            ["created_at"] = createdAt,
            ["updated_at"] = now,
            ["shutdown"] = null,
            ["clients"] = new JsonArray(),
            ["last_error"] = error,
        };

        var temporary = Path.Combine(directory,
            $".{Path.GetFileName(_path)}.{Environment.ProcessId}.tmp");
        using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write,
                   FileShare.None, 4096, FileOptions.WriteThrough))
        {
            using var writer = new Utf8JsonWriter(stream);
            record.WriteTo(writer);
            writer.Flush();
            stream.Flush(flushToDisk: true);
        }
        File.Move(temporary, _path, overwrite: true);
    }

    private JsonObject ReadExisting()
    {
        if (!File.Exists(_path)) return new JsonObject();
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(_path));
            if (node is not JsonObject record || record["schema"]?.GetValue<int>() != Schema)
            {
                return new JsonObject();
            }
            if (record["generation"] is JsonValue generation &&
                generation.GetValue<string>() != _generation)
            {
                throw new IOException("another helper generation owns the registry");
            }
            return record;
        }
        catch (JsonException)
        {
            return new JsonObject();
        }
    }

    private static JsonObject Identity(int pid, (long Seconds, long Microseconds) start,
        string? executable) => new()
    {
        ["pid"] = pid,
        ["start_seconds"] = start.Seconds,
        ["start_microseconds"] = start.Microseconds,
        ["executable"] = executable,
    };
}

public static class ProcessIdentity
{
    public static (long Seconds, long Microseconds) Start(int pid)
    {
        using var process = Process.GetProcessById(pid);
        var start = new DateTimeOffset(process.StartTime.ToUniversalTime());
        return (start.ToUnixTimeSeconds(), start.Millisecond * 1000L);
    }
}
