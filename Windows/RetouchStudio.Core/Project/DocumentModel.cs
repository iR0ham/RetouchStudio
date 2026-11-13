using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RetouchStudio.Core.Project;

/// <summary>A crop in normalized photo coordinates, top-left origin.</summary>
public readonly record struct CropValue(double X, double Y, double Width, double Height);

/// <summary>
/// A document orientation: quarter turns, a horizontal mirror and the
/// straighten angle in degrees. Identity means none of the three.
/// </summary>
public readonly record struct OrientationValue(int QuarterTurns, bool Flipped, double Angle)
{
    public static readonly OrientationValue Identity = new(0, false, 0);

    public bool IsIdentity => NormalizeQuarterTurns(QuarterTurns) == 0 && !Flipped && Angle == 0;

    public OrientationValue WithQuarterTurn(int delta) =>
        this with { QuarterTurns = NormalizeQuarterTurns(QuarterTurns + delta) };

    public OrientationValue WithFlip() => this with { Flipped = !Flipped };

    public OrientationValue WithAngle(double angle) => this with { Angle = Math.Round(angle, 2) };

    private static int NormalizeQuarterTurns(int turns) => ((turns % 4) + 4) % 4;
}

/// <summary>
/// The current v4 document record, edited in place. Only fields this host
/// understands are touched; every other key from the file is carried through
/// untouched, exactly as the C ABI returned it.
/// </summary>
public sealed class DocumentModel
{
    /// <summary>
    /// The global colour and light sliders this host exposes, in the order the
    /// panel lists them. The names are the v4 JSON keys, which are the
    /// StudioCore property names.
    /// </summary>
    public static readonly IReadOnlyList<string> GlobalAdjustmentNames = new[]
    {
        "exposure", "contrast", "blacks", "whites", "saturation",
        "vibrance", "warmth", "clarity", "vignette",
    };

    private JsonObject _root;

    public DocumentModel(JsonObject root)
    {
        _root = root;
    }

    public JsonObject Root => _root;

    public static DocumentModel Parse(byte[] utf8)
    {
        var node = JsonNode.Parse(utf8)
            ?? throw new JsonException("the document is empty");
        if (node is not JsonObject obj)
        {
            throw new JsonException("the document is not a JSON object");
        }
        return new DocumentModel(obj);
    }

    /// <summary>Replaces the whole record, which is how an undo step lands.</summary>
    public void Adopt(byte[] utf8)
    {
        _root = Parse(utf8).Root;
    }

    public byte[] ToUtf8() => Encoding.UTF8.GetBytes(_root.ToJsonString());

    public int Version
    {
        get => ReadInt("version") ?? 4;
        set => _root["version"] = value;
    }

    public string ImagePath
    {
        get => ReadString("imagePath") ?? "";
        set => _root["imagePath"] = value;
    }

    public string ExportFormat
    {
        get => ReadString("exportFormat") ?? "jpeg";
        set => _root["exportFormat"] = value;
    }

    public double ExportQuality
    {
        get => ReadDouble("exportQuality") ?? 0.92;
        set => _root["exportQuality"] = Math.Round(value, 2);
    }

    public int? ExportLongEdge
    {
        get => ReadInt("exportLongEdge");
        set
        {
            if (value is null or 0)
            {
                _root.Remove("exportLongEdge");
            }
            else
            {
                _root["exportLongEdge"] = value.Value;
            }
        }
    }

    public double Adjustment(string name)
    {
        var adjustments = Adjustments;
        return adjustments?[name] is JsonValue value && value.TryGetValue<double>(out var number)
            ? number
            : 0;
    }

    /// <summary>
    /// Stores one slider value. Zero removes the key, so "no change" and "key
    /// absent" are the same bytes and an undo step is not created by touching a
    /// slider and putting it back.
    /// </summary>
    public void SetAdjustment(string name, double value)
    {
        var rounded = Math.Round(value, 1);
        var adjustments = AdjustmentsMutable();
        if (rounded == 0)
        {
            adjustments.Remove(name);
        }
        else
        {
            adjustments[name] = rounded;
        }
    }

    public CropValue? Crop
    {
        get
        {
            if (_root["crop"] is not JsonObject crop)
            {
                return null;
            }
            return new CropValue(ReadDouble(crop, "x") ?? 0, ReadDouble(crop, "y") ?? 0,
                                 ReadDouble(crop, "width") ?? 0,
                                 ReadDouble(crop, "height") ?? 0);
        }
        set
        {
            if (value is null || value.Value.Width <= 0 || value.Value.Height <= 0)
            {
                _root.Remove("crop");
                return;
            }
            var crop = value.Value;
            _root["crop"] = new JsonObject
            {
                ["x"] = Math.Round(crop.X, 6),
                ["y"] = Math.Round(crop.Y, 6),
                ["width"] = Math.Round(crop.Width, 6),
                ["height"] = Math.Round(crop.Height, 6),
            };
        }
    }

    public OrientationValue Orientation
    {
        get
        {
            if (_root["orientation"] is not JsonObject orientation)
            {
                return OrientationValue.Identity;
            }
            var turns = ReadInt(orientation, "quarterTurns") ?? 0;
            var flipped = orientation["flipped"] is JsonValue f && f.TryGetValue<bool>(out var b) && b;
            var angle = ReadDouble(orientation, "angle") ?? 0;
            return new OrientationValue(((turns % 4) + 4) % 4, flipped, angle);
        }
        set
        {
            if (value.IsIdentity)
            {
                _root.Remove("orientation");
                return;
            }
            var orientation = new JsonObject();
            if (value.QuarterTurns != 0)
            {
                orientation["quarterTurns"] = value.QuarterTurns;
            }
            if (value.Flipped)
            {
                orientation["flipped"] = true;
            }
            if (value.Angle != 0)
            {
                orientation["angle"] = Math.Round(value.Angle, 2);
            }
            _root["orientation"] = orientation;
        }
    }

    /// <summary>
    /// A deep copy of one top-level record, for building a render request
    /// without touching the document.
    /// </summary>
    public JsonNode? CopyField(string name) => _root[name]?.DeepClone();

    private JsonObject? Adjustments =>
        _root["adjustments"] as JsonObject;

    private JsonObject AdjustmentsMutable()
    {
        if (_root["adjustments"] is JsonObject existing)
        {
            return existing;
        }
        var created = new JsonObject();
        _root["adjustments"] = created;
        return created;
    }

    private string? ReadString(string key) =>
        _root[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private double? ReadDouble(string key) => _root[key] is { } node ? ReadDouble(node) : null;

    private int? ReadInt(string key) => _root[key] is { } node ? ReadInt(node) : null;

    private static double? ReadDouble(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;

    private static int? ReadInt(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<int>(out var integer))
        {
            return integer;
        }
        return value.TryGetValue<double>(out var number) ? (int)number : null;
    }

    private static double? ReadDouble(JsonObject root, string key) =>
        root[key] is { } node ? ReadDouble(node) : null;

    private static int? ReadInt(JsonObject root, string key) =>
        root[key] is { } node ? ReadInt(node) : null;
}
