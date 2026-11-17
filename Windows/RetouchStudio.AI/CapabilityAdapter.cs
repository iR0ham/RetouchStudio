using System.Text.Json.Nodes;

namespace RetouchStudio.AI;

/// <summary>
/// The host-side capability adapter. It asks the worker for its answer and
/// refuses any reply that drifts from the frozen rules: an unknown id, a
/// missing reason, support without evidence, or a different vocabulary.
/// </summary>
public sealed record CapabilityReport(string Vocabulary, string Platform,
    string Provider, IReadOnlyList<Capabilities.CapabilityRecord> Records)
{
    public Capabilities.CapabilityRecord? Find(string capabilityId) =>
        Records.FirstOrDefault(record => record.CapabilityId == capabilityId);

    public static CapabilityReport Parse(JsonObject result)
    {
        var vocabulary = String(result["vocabulary"]);
        if (vocabulary != Capabilities.Vocabulary)
            throw new InvalidDataException(
                $"unsupported capability vocabulary {vocabulary ?? "(missing)"}");
        var provider = String(result["provider"])
            ?? throw new InvalidDataException("the capability report has no provider");
        var platform = String(result["platform"]) ?? "";
        if (result["capabilities"] is not JsonArray records)
            throw new InvalidDataException("the capability report has no list");

        var parsed = new List<Capabilities.CapabilityRecord>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in records)
        {
            if (node is not JsonObject json)
                throw new InvalidDataException("a capability record is not an object");
            var record = Capabilities.CapabilityRecord.Parse(json, provider);
            if (!seen.Add(record.CapabilityId))
                throw new InvalidDataException(
                    $"{record.CapabilityId} is reported twice");
            parsed.Add(record);
        }
        foreach (var id in Capabilities.VocabularyIds)
        {
            if (!seen.Contains(id))
                throw new InvalidDataException($"the report omits {id}");
        }
        return new CapabilityReport(vocabulary!, platform, provider, parsed);
    }

    private static string? String(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}

public static class CapabilityAdapter
{
    /// <summary>
    /// Fetches `capability.list` from the named pipe. A worker that is not
    /// running fails immediately as E_WORKER_MISSING; it is never reported as
    /// a timeout or as a supported capability.
    /// </summary>
    public static async Task<CapabilityReport> FetchAsync(string pipeName,
        TimeSpan? timeout = null)
    {
        var client = new WorkerClient(pipeName);
        var result = await client.CallAsync("capability.list", null, timeout);
        return CapabilityReport.Parse(result);
    }
}
