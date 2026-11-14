using System.Text.Json.Nodes;
using RetouchStudio.Core.Interop;
using RetouchStudio.Core.Project;

namespace RetouchStudio.Core.Render;

/// <summary>
/// The export decisions StudioCore made for one request. The Windows host
/// follows this plan instead of choosing a format or size of its own, so the
/// shared rules — not the host — decide what a file should be.
/// </summary>
public sealed record ExportPlan(
    string Format,
    int Width,
    int Height,
    bool Upscales,
    bool AppliesAnalysis,
    bool AppliesWatermark,
    bool FlattensAlpha,
    int BitsPerChannel,
    string ColorSpace,
    bool CarriesSourceMetadata)
{
    public static ExportPlan Parse(byte[] json)
    {
        var root = JsonNode.Parse(json) as JsonObject
            ?? throw new InvalidOperationException("the render plan is not a JSON object");
        var pixelSize = root["pixelSize"] as JsonObject;
        return new ExportPlan(
            Format: root["format"]?.GetValue<string>() ?? "jpeg",
            Width: (int)Math.Round(pixelSize?["width"]?.GetValue<double>() ?? 0),
            Height: (int)Math.Round(pixelSize?["height"]?.GetValue<double>() ?? 0),
            Upscales: root["upscales"]?.GetValue<bool>() ?? false,
            AppliesAnalysis: root["appliesAnalysis"]?.GetValue<bool>() ?? false,
            AppliesWatermark: root["appliesWatermark"]?.GetValue<bool>() ?? false,
            FlattensAlpha: root["flattensAlpha"]?.GetValue<bool>() ?? false,
            BitsPerChannel: root["bitsPerChannel"]?.GetValue<int>() ?? 8,
            ColorSpace: root["colorSpace"]?.GetValue<string>() ?? "source",
            CarriesSourceMetadata: root["carriesSourceMetadata"]?.GetValue<bool>() ?? false);
    }
}

/// <summary>
/// Builds the two JSON documents <c>sc_render_plan</c> takes. The document
/// fields are copied, not reinterpreted: the shared decoder owns their shape.
/// </summary>
public static class RenderRequests
{
    /// <summary>
    /// The export this host offers. Analysis callouts, stamps and the AI
    /// upscaler are not implemented here, so the request says so instead of
    /// asking the planner for work the renderer cannot do.
    /// </summary>
    public static byte[] Build(DocumentModel document, string format, double quality,
                               int longEdge, bool stripsPrivacyMetadata = true)
    {
        var request = new JsonObject
        {
            ["adjustments"] = document.CopyField("adjustments") ?? new JsonObject(),
            ["healSpots"] = document.CopyField("healSpots") ?? new JsonArray(),
            ["stickers"] = document.CopyField("stickers") ?? new JsonArray(),
            ["aiEdits"] = document.CopyField("aiEdits") ?? new JsonArray(),
            ["analysis"] = document.CopyField("analysis") ?? new JsonObject(),
            ["crop"] = document.CopyField("crop"),
            ["orientation"] = document.CopyField("orientation") ?? new JsonObject(),
            ["selectedFaceIndex"] = document.CopyField("selectedFace"),
            ["format"] = format,
            ["quality"] = Math.Round(quality, 2),
            ["longEdge"] = longEdge > 0 ? longEdge : null,
            ["stripsPrivacyMetadata"] = stripsPrivacyMetadata,
            ["includeStamps"] = false,
            ["includeAnalysis"] = false,
            ["aiUpscale"] = false,
            ["watermark"] = new JsonObject
            {
                ["enabled"] = false,
                ["text"] = "",
                ["position"] = "bottomRight",
                ["opacity"] = 0.65,
                ["sizePercent"] = 3.0,
            },
        };
        return System.Text.Encoding.UTF8.GetBytes(request.ToJsonString());
    }

    public static byte[] BuildSource(int width, int height, string colorProfileName)
    {
        var source = new JsonObject
        {
            ["pixelSize"] = new JsonObject
            {
                ["width"] = width,
                ["height"] = height,
            },
            ["photoAspect"] = width / (double)height,
            ["faceCount"] = 0,
            ["colorProfileName"] = colorProfileName,
        };
        return System.Text.Encoding.UTF8.GetBytes(source.ToJsonString());
    }

    public static ExportPlan Plan(DocumentModel document, int sourceWidth, int sourceHeight,
                                  string format, double quality, int longEdge,
                                  string colorProfileName = "sRGB",
                                  bool stripsPrivacyMetadata = true)
    {
        var plan = StudioCoreApi.RenderPlan(
            Build(document, format, quality, longEdge, stripsPrivacyMetadata),
            BuildSource(sourceWidth, sourceHeight, colorProfileName));
        return ExportPlan.Parse(plan);
    }
}
