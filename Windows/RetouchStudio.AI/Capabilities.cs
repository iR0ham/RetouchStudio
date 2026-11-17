using System.Text.Json.Nodes;
using RetouchStudio.AI.Models;

namespace RetouchStudio.AI;

/// <summary>
/// The frozen W5-0 capability vocabulary and this adapter's truthful answer.
///
/// The Windows adapter has no enabled inference path in W5-3: W5-4's ONNX
/// artifact is not approved, and face, mask, heal and generative capabilities
/// belong to later milestones. Every record therefore carries a state and a
/// reason; nothing is claimed `supported` merely because ONNX Runtime or a
/// catalog entry exists.
/// </summary>
public static class Capabilities
{
    public const string Vocabulary = "capabilities/1";
    public const string Supported = "supported";
    public const string RequiresModel = "requires_model";
    public const string Blocked = "blocked";
    public const string Unsupported = "unsupported";

    public static readonly IReadOnlyList<string> VocabularyIds = new[]
    {
        "face.analysis", "face.parsing", "mask.subject", "mask.click",
        "matte.fine", "inpaint.spot", "inpaint.object", "generative.edit",
        "generative.reimagine", "generative.outpaint", "background.replace",
        "upscale.2x", "upscale.4x", "enhance.photo", "restore.photo",
        "portrait.ai",
    };

    private static readonly Dictionary<string, (string State, string Reason)> Fixed =
        new(StringComparer.Ordinal)
        {
            ["face.analysis"] = (Blocked,
                "the Windows landmark model decision is pending (F1); no support is claimed"),
            ["face.parsing"] = (Blocked,
                "no learned face-parsing model is adopted for Windows (follow-on F2)"),
            ["mask.subject"] = (Blocked,
                "Windows subject and face masks wait on the W3/F1 model decision"),
            ["mask.click"] = (Blocked,
                "no promptable-mask model is approved for Windows (follow-on S2)"),
            ["matte.fine"] = (Blocked,
                "no fine-matte model with cleared commercial rights is adopted (S2)"),
            ["inpaint.spot"] = (Unsupported,
                "the CPU-only Windows baseline has no approved inpaint engine (follow-on H1)"),
            ["inpaint.object"] = (Unsupported,
                "the CPU-only Windows baseline has no approved object-removal engine (H1)"),
            ["generative.edit"] = (Unsupported,
                "diffusion-class generation is not part of the CPU-only Windows baseline (G1)"),
            ["generative.reimagine"] = (Unsupported,
                "diffusion-class generation is not part of the CPU-only Windows baseline (G1)"),
            ["generative.outpaint"] = (Blocked,
                "no licensed outpainting engine; the product refuses outpainting"),
            ["background.replace"] = (Unsupported,
                "background replacement needs a person matte and is a follow-on (B1)"),
            ["upscale.2x"] = (Unsupported,
                "2× output is not implemented (follow-on U1)"),
            ["upscale.4x"] = (Blocked,
                "the Windows Swin2SR x4 ONNX artifact is not approved; W5-4 Windows is blocked"),
            ["enhance.photo"] = (Unsupported,
                "classical enhancement only; no AI enhancer model on Windows (E1)"),
            ["restore.photo"] = (Unsupported,
                "classical restoration only; no AI restoration model on Windows (E1)"),
            ["portrait.ai"] = (Unsupported,
                "no AI portrait model; classical portrait processing stays the default (P1)"),
        };

    public sealed record CapabilityRecord(string CapabilityId, string State,
        string Provider, string? ModelId, string? ModelVersion,
        string? Evidence, string? Reason)
    {
        public JsonObject ToJson()
        {
            var record = new JsonObject
            {
                ["capabilityId"] = CapabilityId,
                ["state"] = State,
                ["provider"] = Provider,
            };
            if (ModelId is not null) record["modelId"] = ModelId;
            if (ModelVersion is not null) record["modelVersion"] = ModelVersion;
            if (Evidence is not null) record["evidence"] = Evidence;
            if (Reason is not null) record["reason"] = Reason;
            return record;
        }

        public static CapabilityRecord Parse(JsonObject json, string provider)
        {
            var id = String(json["capabilityId"])
                ?? throw new InvalidDataException("a capability record has no id");
            var state = String(json["state"])
                ?? throw new InvalidDataException($"{id} has no state");
            if (state is not (Supported or RequiresModel or Blocked or Unsupported))
                throw new InvalidDataException($"{id} has an unknown state {state}");
            if (!VocabularyIds.Contains(id, StringComparer.Ordinal))
                throw new InvalidDataException($"unknown capability {id}");
            var recordProvider = String(json["provider"]) ?? provider;
            var evidence = String(json["evidence"]);
            var reason = String(json["reason"]);
            if (state == Supported && string.IsNullOrWhiteSpace(evidence))
                throw new InvalidDataException($"{id} claims support without evidence");
            if (state != Supported && string.IsNullOrWhiteSpace(reason))
                throw new InvalidDataException($"{id} has no reason for {state}");
            return new CapabilityRecord(id, state, recordProvider, String(json["modelId"]),
                String(json["modelVersion"]), evidence, reason);
        }
    }

    public static (string Provider, bool Available, string? Error) ProviderState()
    {
        var result = Providers.Ensure();
        return (Providers.Id, result.Available, result.Error);
    }

    /// <summary>
    /// One record per frozen capability. A provider that did not initialise
    /// blocks every capability before any other reason is considered.
    /// </summary>
    public static IReadOnlyList<CapabilityRecord> Report()
    {
        var (provider, available, error) = ProviderState();
        return VocabularyIds.Select(id =>
        {
            var (state, reason) = Fixed[id];
            if (!available)
            {
                return new CapabilityRecord(id, Blocked, provider, null, null, null,
                    $"the {Providers.Id} provider did not initialise: {error}");
            }
            return new CapabilityRecord(id, state, provider, null, null, null, reason);
        }).ToArray();
    }

    public static JsonObject Result()
    {
        var records = Report();
        return new JsonObject
        {
            ["contractVersion"] = Protocol.ContractVersion,
            ["vocabulary"] = Vocabulary,
            ["platform"] = ModelCatalog.Platform,
            ["provider"] = Providers.Id,
            ["capabilities"] = new JsonArray(records.Select(r => (JsonNode)r.ToJson())
                .ToArray()),
        };
    }

    /// <summary>A capability is runnable only when it reports `supported`.</summary>
    public static CapabilityRecord? Runnable(string capabilityId) =>
        Report().FirstOrDefault(record => record.CapabilityId == capabilityId
                                          && record.State == Supported);

    public static CapabilityRecord? Find(string capabilityId) =>
        Report().FirstOrDefault(record => record.CapabilityId == capabilityId);

    private static string? String(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
}
