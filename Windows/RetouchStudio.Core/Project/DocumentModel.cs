using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RetouchStudio.Core.Project;

/// <summary>A crop in normalized upright-frame coordinates, top-left origin —
/// the record macOS stores against the oriented frame.</summary>
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
/// The current v4/v5 document record, edited in place. Only fields this host
/// understands are touched; every other key from the file is carried through
/// untouched, exactly as the C ABI returned it. A v5 file arrives as v5 — its
/// masks and face identities ride through this raw tree on a save.
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
    /// The edits a project carries that this host cannot render, in the words a
    /// warning shows. A macOS project can hold all of them; exporting one here
    /// would silently drop them, so the host asks before it writes.
    /// </summary>
    public IReadOnlyList<string> UnsupportedEdits
    {
        get
        {
            var found = new List<string>();
            if (HasItems("healSpots"))
            {
                found.Add("heal spots");
            }
            if (HasItems("stickers"))
            {
                found.Add("stickers");
            }
            if (HasItems("aiEdits"))
            {
                found.Add("AI patches");
            }
            // A mask is user data this host cannot render; an export that
            // ignored it would change the edit the owner drew.
            if (HasItems("masks"))
            {
                found.Add("masked selections");
            }
            if (AnalysisEnabled)
            {
                found.Add("analysis callouts");
            }
            // The nine global sliders are the only adjustment amounts this
            // host renders. Every other amount macOS writes is named here so
            // an export cannot silently drop it.
            if (AnyAmount("smooth", "blemish", "wrinkle", "skinToneEvens",
                          "darkCircles", "skinBrighten"))
            {
                found.Add("skin retouching");
            }
            if (AnyAmount("skinFinish", "shine", "splitTone"))
            {
                found.Add("skin finish");
            }
            if (AnyAmount("teethWhiten", "teethAlign"))
            {
                found.Add("teeth whitening");
            }
            if (AnyAmount("eyeBrighten", "eyeSharpen", "irisEnhance", "lashDarken"))
            {
                found.Add("eye enhancement");
            }
            if (AnyAmount("eyeSize", "noseSize", "noseTip", "lipSize", "cheekSize",
                          "jawWidth", "chinLength", "faceWidth", "faceLength"))
            {
                found.Add("face reshaping");
            }
            if (AnyAmount("lipTint", "blush", "browDefine", "eyeshadow", "eyeliner",
                          "contour", "lipGloss"))
            {
                found.Add("makeup");
            }
            // The look is the one edit macOS writes as two fields: the
            // identifier names the grade, the strength blends it in. Either
            // half alone can ask for a grade this host cannot render, so both
            // are checked.
            if (ReadAdjustmentString("lookID") is { Length: > 0 } || AnyAmount("lookStrength"))
            {
                found.Add("a look");
            }
            if (AnyAmount("grain"))
            {
                found.Add("film grain");
            }
            if (AnyAmount("curveShadows", "curveMidtones", "curveHighlights"))
            {
                found.Add("curves");
            }
            if (AnyAmountInArray("hslHue") || AnyAmountInArray("hslSaturation")
                || AnyAmountInArray("hslLuminance"))
            {
                found.Add("HSL colour");
            }
            if (AnyAmount("bodySmooth", "bodyTone", "bodySlim", "bodyWaist",
                          "bodyArms", "bodyLegs"))
            {
                found.Add("body adjustments");
            }
            if (AnyAmount("backgroundBlur", "backgroundTone", "backgroundSaturation",
                          "backgroundFill")
                || ReadAdjustmentBool("backgroundRemove")
                || ReadAdjustmentString("backgroundImage") is { Length: > 0 })
            {
                found.Add("background adjustments");
            }
            if (AnyAmount("hairColor", "hairShine", "hairVolume"))
            {
                found.Add("hair adjustments");
            }
            if (AnyAmount("lensTint"))
            {
                found.Add("lens tint");
            }
            // autoRetouchStrength and autoColorStrength are the settings for
            // those tools, not edits: the settings ride every project file
            // macOS writes, while an applied Smart Analyze result is merged
            // into the normal adjustments. Treating them as edits warned on
            // every new document, so they are deliberately absent here.
            return found;
        }
    }

    private double Amount(string key) =>
        Adjustments is { } adjustments ? ReadDouble(adjustments, key) ?? 0 : 0;

    private bool AnyAmount(params string[] keys) => keys.Any(key => Amount(key) != 0);

    private bool AnyAmountInArray(string key) =>
        Adjustments?[key] is JsonArray values
        && values.Any(value => ReadDouble(value) is not (null or 0.0));

    private string? ReadAdjustmentString(string key) =>
        Adjustments?[key] is JsonValue value
        && value.TryGetValue<string>(out var text) ? text : null;

    private bool ReadAdjustmentBool(string key) =>
        Adjustments?[key] is JsonValue value
        && value.TryGetValue<bool>(out var flag) && flag;

    private bool AnalysisEnabled =>
        _root["analysis"] is JsonObject analysis
        && analysis["isEnabled"] is JsonValue flag
        && flag.TryGetValue<bool>(out var enabled) && enabled;

    private bool HasItems(string key) =>
        _root[key] is JsonArray { Count: > 0 };

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
