using System.Text;
using System.Text.Json.Nodes;
using RetouchStudio.Core.Imaging;
using RetouchStudio.Core.Interop;
using RetouchStudio.Core.Project;
using RetouchStudio.Core.Render;
using RetouchStudio.Imaging;

namespace RetouchStudio.Tests;

/// <summary>
/// Headless checks for the Windows host. Every check names the behaviour it
/// proves; a failure prints the check and the test run exits non-zero, so the
/// CI job fails on a real defect instead of on a missing log line.
/// </summary>
internal static class Program
{
    private static int _checks;
    private static int _failures;

    private static int Main()
    {
        var root = Path.Combine(Path.GetTempPath(),
                                "retouch-host-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            Abi();
            DocumentAndHistory(root);
            UnknownFieldPreservation(root);
            Geometry(root);
            Pixels();
            Adjustments();
            Codec(root);
            Export(root);
            Metadata(root);
            Interchange(root);
        }
        catch (Exception error)
        {
            _failures++;
            Console.WriteLine($"  x unhandled: {error}");
        }
        finally
        {
            try
            {
                Directory.Delete(root, recursive: true);
            }
            catch (IOException)
            {
            }
        }

        if (_failures == 0)
        {
            Console.WriteLine($"WINDOWS HOST TESTS: PASS ({_checks} checks)");
            return 0;
        }
        Console.WriteLine($"WINDOWS HOST TESTS: FAIL ({_failures} of {_checks} checks)");
        return 1;
    }

    private static void Abi()
    {
        try
        {
            StudioCoreApi.VerifyAbi();
            Pass("studioscore_core.dll reports ABI version 1");
        }
        catch (Exception error)
        {
            Fail("studioscore_core.dll loads", error.Message);
        }
    }

    private static void DocumentAndHistory(string root)
    {
        var imagePath = Path.Combine(root, "photo.png");
        using var session = ProjectSession.Create(imagePath);
        var model = session.Document;

        Check("a new document is version 4", model.Version == 4);
        Check("the image path is stored", model.ImagePath == imagePath);
        Check("a new document starts clean", !session.IsDirty());

        model.SetAdjustment("exposure", 12.46);
        Check("a slider rounds to one decimal", model.Adjustment("exposure") == 12.5);
        Check("an edit makes the document dirty", session.IsDirty());
        // StudioCore counts the pending edit as one step back to the last
        // committed state, so it is already undoable before the commit.
        Check("an uncommitted edit is already undoable",
              session.HistoryFlags().CanUndo);

        session.Commit();
        Check("a committed edit creates an undo step", session.HistoryFlags().CanUndo);
        Check("undo restores the previous state",
              session.Undo() && model.Adjustment("exposure") == 0);
        Check("undo returns to the clean baseline", !session.IsDirty());
        Check("redo reapplies the edit",
              session.Redo() && model.Adjustment("exposure") == 12.5);

        var projectPath = Path.Combine(root, "photo.retouch");
        session.Save(projectPath);
        Check("save writes the project file", File.Exists(projectPath));
        Check("save marks the document clean", !session.IsDirty());

        var saved = JsonNode.Parse(File.ReadAllText(projectPath))!.AsObject();
        Check("the file is v4 on disk", saved["version"]!.GetValue<int>() == 4);
        Check("the edit is in the file",
              saved["adjustments"]!["exposure"]!.GetValue<double>() == 12.5);

        using var reopened = ProjectSession.Open(projectPath);
        Check("the project reopens with its edit",
              reopened.Document.Adjustment("exposure") == 12.5);
        Check("a reopened project is clean", !reopened.IsDirty());

        model.SetAdjustment("contrast", 0);
        Check("zero removes the slider key",
              model.Root["adjustments"] is JsonObject adjustments
              && adjustments["contrast"] is null);
    }

    private static void UnknownFieldPreservation(string root)
    {
        var imagePath = Path.Combine(root, "photo.png");
        var source = Path.Combine(root, "future.retouch");
        var original = new JsonObject
        {
            ["version"] = 4,
            ["imagePath"] = imagePath,
            ["adjustments"] = new JsonObject(),
            ["exportFormat"] = "jpeg",
            ["exportQuality"] = 0.92,
            ["autoRetouchStrength"] = 50,
            ["futureField"] = true,
        };
        File.WriteAllText(source, original.ToJsonString());

        var rewritten = Path.Combine(root, "rewritten.retouch");
        using (var session = ProjectSession.Open(source))
        {
            session.Document.SetAdjustment("warmth", 7);
            session.Save(rewritten);
        }

        var saved = JsonNode.Parse(File.ReadAllText(rewritten))!.AsObject();
        Check("an unknown top-level key survives a save",
              saved["futureField"]?.GetValue<bool>() == true);
        Check("the host's own edit is written",
              saved["adjustments"]!["warmth"]!.GetValue<double>() == 7);
    }

    private static void Geometry(string root)
    {
        using var session = ProjectSession.Create(Path.Combine(root, "photo.png"));
        var model = session.Document;

        Check("orientation starts identity", model.Orientation.IsIdentity);
        model.Orientation = model.Orientation.WithQuarterTurn(1)
                                          .WithFlip()
                                          .WithAngle(2.5);
        var orientation = model.Orientation;
        Check("a quarter turn is kept", orientation.QuarterTurns == 1);
        Check("the mirror is kept", orientation.Flipped);
        Check("the straighten angle is kept", orientation.Angle == 2.5);

        model.Orientation = OrientationValue.Identity;
        Check("identity orientation leaves no key", model.Root["orientation"] is null);
        model.Orientation = model.Orientation.WithQuarterTurn(-1);
        Check("a negative turn normalizes to three",
              model.Orientation.QuarterTurns == 3);
        model.Orientation = OrientationValue.Identity;

        Check("crop starts empty", model.Crop is null);
        model.Crop = new CropValue(0.1, 0.2, 0.5, 0.6);
        var crop = model.Crop ?? default;
        Check("crop round-trips",
              crop.X == 0.1 && crop.Y == 0.2 && crop.Width == 0.5 && crop.Height == 0.6);
        model.Crop = new CropValue(0, 0, 0, 0);
        Check("an empty crop leaves no key", model.Crop is null);

        model.ExportLongEdge = 2048;
        Check("the export long edge is stored", model.ExportLongEdge == 2048);
        model.ExportLongEdge = null;
        Check("a null long edge leaves no key", model.Root["exportLongEdge"] is null);
    }

    private static void Pixels()
    {
        var source = new PixelBuffer(4, 2);
        for (var y = 0; y < 2; y++)
        {
            for (var x = 0; x < 4; x++)
            {
                Put(source, x, y, r: (byte)(10 + x + y * 4));
            }
        }

        var cropped = source.Crop(new CropValue(0.5, 0, 0.5, 1));
        Check("crop cuts the requested frame",
              cropped.Width == 2 && cropped.Height == 2);
        Check("crop keeps the right pixels", Get(cropped, 0, 0).R == 12);

        var pair = new PixelBuffer(2, 1);
        Put(pair, 0, 0, r: 17);
        Put(pair, 1, 0, r: 200);

        var turned = pair.RotateQuarterClockwise();
        Check("a quarter turn swaps the axes",
              turned.Width == 1 && turned.Height == 2);
        Check("a quarter turn keeps the top-left pixel", Get(turned, 0, 0).R == 17);
        Check("a quarter turn moves the next pixel down", Get(turned, 0, 1).R == 200);

        var flipped = pair.FlipHorizontally();
        Check("a mirror swaps left and right",
              Get(flipped, 0, 0).R == 200 && Get(flipped, 1, 0).R == 17);

        var oriented = pair.ApplyOrientation(new OrientationValue(0, true, 0));
        Check("apply-orientation mirrors first", Get(oriented, 0, 0).R == 200);

        var wide = new PixelBuffer(8, 4);
        var resized = wide.ResizeLongEdge(4);
        Check("resize sets the long edge",
              resized.Width == 4 && resized.Height == 2);

        var transparent = new PixelBuffer(1, 1);
        Put(transparent, 0, 0, r: 0, g: 0, b: 0, a: 0);
        var flat = transparent.FlattenOntoWhite();
        var flatPixel = Get(flat, 0, 0);
        Check("flatten composites transparent pixels onto white",
              flatPixel.R == 255 && flatPixel.G == 255 && flatPixel.B == 255
              && flatPixel.A == 255);
    }

    private static void Adjustments()
    {
        var gray = new PixelBuffer(4, 4);
        for (var y = 0; y < 4; y++)
        {
            for (var x = 0; x < 4; x++)
            {
                Put(gray, x, y, r: 60, g: 60, b: 60);
            }
        }

        Check("identity is a true no-op",
              ReferenceEquals(AdjustmentPipeline.Apply(gray, GlobalAdjustments.Identity),
                              gray));

        var brighter = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(100, 0, 0, 0, 0, 0, 0, 0, 0));
        Check("positive exposure brightens", Mean(brighter) > Mean(gray) + 20);

        var darker = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(-100, 0, 0, 0, 0, 0, 0, 0, 0));
        Check("negative exposure darkens", Mean(darker) < Mean(gray) - 10);

        var warm = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 100, 0, 0));
        Check("positive warmth raises red over blue",
              Get(warm, 1, 1).R > Get(warm, 1, 1).B);

        var vignetted = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 0, 100));
        Check("vignette darkens the corner more than the centre",
              Get(vignetted, 0, 0).R < Get(vignetted, 2, 2).R);
    }

    private static void Codec(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(6, 4);
        for (var y = 0; y < 4; y++)
        {
            for (var x = 0; x < 6; x++)
            {
                Put(image, x, y, r: (byte)(20 + x * 20), g: (byte)(20 + y * 30), b: 128);
            }
        }

        var png = Path.Combine(root, "roundtrip.png");
        codec.EncodeAsync(image, png, "png", 1.0).GetAwaiter().GetResult();
        Check("the encoder writes a PNG", File.Exists(png));

        var decoded = codec.DecodeAsync(png).GetAwaiter().GetResult();
        Check("the decoder reports the upright size",
              decoded.Width == 6 && decoded.Height == 4);
        var pixel = Get(decoded, 2, 1);
        Check("PNG colour survives a round trip",
              Math.Abs(pixel.R - 60) <= 3 && Math.Abs(pixel.G - 50) <= 3
              && Math.Abs(pixel.B - 128) <= 3);
        Check("PNG keeps full alpha", pixel.A == 255);
    }

    private static void Export(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(6, 4);
        for (var y = 0; y < 4; y++)
        {
            for (var x = 0; x < 6; x++)
            {
                Put(image, x, y, r: (byte)(40 + x * 20), g: (byte)(40 + y * 30), b: 90);
            }
        }
        var sourcePath = Path.Combine(root, "source.png");
        codec.EncodeAsync(image, sourcePath, "png", 1.0).GetAwaiter().GetResult();

        using var session = ProjectSession.Create(sourcePath);
        session.Document.SetAdjustment("exposure", 15);

        var jpeg = Path.Combine(root, "export.jpg");
        var plan = ExportRunner.ExportAsync(session, codec, jpeg, "jpeg", 0.9, 3)
                               .GetAwaiter().GetResult();
        Check("StudioCore plans the exported size",
              plan.Format == "jpeg" && plan.Width == 3 && plan.Height == 2);
        Check("a JPEG plan is 8-bit and flattened",
              plan.BitsPerChannel == 8 && plan.FlattensAlpha);
        Check("the export writes a JPEG", File.Exists(jpeg));

        var exported = codec.DecodeAsync(jpeg).GetAwaiter().GetResult();
        Check("the export follows the plan",
              exported.Width == plan.Width && exported.Height == plan.Height);

        var pngPlan = RenderRequests.Plan(session.Document, 6, 4, "png", 1.0, 0);
        Check("a PNG plan keeps 16-bit depth and alpha",
              pngPlan.Format == "png" && pngPlan.BitsPerChannel == 16
              && !pngPlan.FlattensAlpha);

        try
        {
            ExportRunner.ExportAsync(session, codec, sourcePath, "jpeg", 0.9, 0)
                        .GetAwaiter().GetResult();
            Fail("the export refuses to overwrite the opened photo", "no exception");
        }
        catch (InvalidOperationException)
        {
            Pass("the export refuses to overwrite the opened photo");
        }
    }

    /// <summary>
    /// The metadata policy: a photograph keeps its camera keys when the caller
    /// turns stripping off, keeps only the resolution when it is on, and PNG
    /// carries no EXIF on this host because the Windows metadata API does not
    /// map EXIF onto PNG chunks.
    /// </summary>
    private static void Metadata(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(8, 6);
        for (var y = 0; y < 6; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                Put(image, x, y, r: 90, g: 110, b: 130);
            }
        }

        var source = Path.Combine(root, "metadata-source.jpg");
        var sourceMetadata = new ImageMetadata(new Dictionary<string, object>
        {
            ["System.Photo.CameraManufacturer"] = "Retouch",
            ["System.Photo.CameraModel"] = "RS-Test",
            ["System.Photo.IsoSpeed"] = (ushort)400,
        }, 300, 300);
        codec.EncodeAsync(image, source, "jpeg", 0.95, sourceMetadata, stripPrivacyMetadata: false)
             .GetAwaiter().GetResult();

        var read = codec.ReadMetadataAsync(source).GetAwaiter().GetResult();
        Check("the decoder reads the camera model",
              Text(read, "System.Photo.CameraModel") == "RS-Test");
        Check("the decoder reports the source resolution",
              Math.Abs(read.DpiX - 300) < 1);

        using var session = ProjectSession.Create(source);

        var kept = Path.Combine(root, "metadata-kept.jpg");
        ExportRunner.ExportAsync(session, codec, kept, "jpeg", 0.9, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var keptMeta = codec.ReadMetadataAsync(kept).GetAwaiter().GetResult();
        Check("keeping metadata carries the camera model",
              Text(keptMeta, "System.Photo.CameraModel") == "RS-Test");
        Check("keeping metadata carries the ISO",
              keptMeta.Properties.TryGetValue("System.Photo.IsoSpeed", out var iso)
              && Convert.ToDouble(iso) == 400);
        Check("keeping metadata keeps the resolution",
              Math.Abs(keptMeta.DpiX - 300) < 1);

        Check("a kept export carries no GPS key",
              !keptMeta.Properties.Keys.Any(key => key.StartsWith("System.GPS.", StringComparison.Ordinal)));

        var stripped = Path.Combine(root, "metadata-stripped.jpg");
        ExportRunner.ExportAsync(session, codec, stripped, "jpeg", 0.9, 0)
                             .GetAwaiter().GetResult();
        var strippedMeta = codec.ReadMetadataAsync(stripped).GetAwaiter().GetResult();
        Check("stripping drops the camera model",
              !strippedMeta.Properties.ContainsKey("System.Photo.CameraModel"));
        Check("stripping drops the GPS block",
              !strippedMeta.Properties.Keys.Any(key => key.StartsWith("System.GPS.", StringComparison.Ordinal)));
        Check("stripping keeps the resolution",
              Math.Abs(strippedMeta.DpiX - 300) < 1);

        var tiff = Path.Combine(root, "metadata-kept.tiff");
        ExportRunner.ExportAsync(session, codec, tiff, "tiff", 1.0, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var tiffMeta = codec.ReadMetadataAsync(tiff).GetAwaiter().GetResult();
        Check("keeping metadata works for TIFF",
              Text(tiffMeta, "System.Photo.CameraModel") == "RS-Test");

        var png = Path.Combine(root, "metadata-kept.png");
        ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var pngMeta = codec.ReadMetadataAsync(png).GetAwaiter().GetResult();
        Check("PNG carries no EXIF on this host",
              !pngMeta.Properties.ContainsKey("System.Photo.CameraModel"));

        Probe(root, codec);
    }

    /// <summary>
    /// A diagnostic, not a gate: writes one candidate key per file and prints
    /// whether it survives, so the allowlist grows from measured behaviour
    /// instead of from documentation. A dropped key is not asserted here
    /// because the list is deliberately wider than what a JPEG encoder keeps.
    /// </summary>
    private static void Probe(string root, WindowsImageCodec codec)
    {
        var image = new PixelBuffer(4, 3);
        var probes = new (string Key, object Value)[]
        {
            ("System.Photo.CameraManufacturer", "Probe"),
            ("System.Photo.DateTaken", new DateTime(2024, 5, 17, 10, 30, 0, DateTimeKind.Unspecified)),
            ("System.Photo.ExposureTime", 0.008),
            ("System.Photo.FNumber", 2.8),
            ("System.Photo.IsoSpeed", (ushort)400),
            ("System.Photo.Flash", (ushort)16),
            ("System.Photo.WhiteBalance", (ushort)1),
            ("System.GPS.LatitudeRef", "N"),
            ("System.GPS.LongitudeRef", "E"),
            ("System.GPS.Latitude", new[] { 35.0, 41.0, 12.0 }),
            ("System.GPS.Longitude", new[] { 51.0, 25.0, 3.0 }),
            ("System.GPS.Altitude", 1200.0),
            ("System.Comment", "Retouch Studio probe"),
        };
        foreach (var (key, value) in probes)
        {
            try
            {
                var path = Path.Combine(root, "probe-" + key.Replace('.', '-') + ".jpg");
                codec.EncodeAsync(image, path, "jpeg", 0.95,
                                  new ImageMetadata(new Dictionary<string, object> { [key] = value }),
                                  stripPrivacyMetadata: false).GetAwaiter().GetResult();
                var read = codec.ReadMetadataAsync(path).GetAwaiter().GetResult();
                Console.WriteLine($"  probe {key}: " +
                                  (read.Properties.ContainsKey(key) ? "kept" : "dropped"));
            }
            catch (Exception error)
            {
                Console.WriteLine($"  probe {key}: failed ({error.Message})");
            }
        }
    }

    private static string Text(ImageMetadata metadata, string key) =>
        metadata.Properties.TryGetValue(key, out var value) ? value as string ?? string.Empty : string.Empty;

    /// <summary>
    /// The interchange gate: a project written on macOS opens, edits and saves
    /// on Windows without losing a supported record. The fixtures are the same
    /// files the macOS suite pins, so both hosts are measured against one file.
    /// The comparison is over parsed JSON, not bytes: whitespace and key order
    /// are not part of the portable contract.
    /// </summary>
    private static void Interchange(string root)
    {
        var repo = RepoRoot();
        var v4Fixture = JsonNode.Parse(Encoding.UTF8.GetString(
            File.ReadAllBytes(Path.Combine(repo,
                "Tests/Fixtures/ProjectV4/project-v4-full.retouch"))))!;
        var v3Fixture = JsonNode.Parse(Encoding.UTF8.GetString(
            File.ReadAllBytes(Path.Combine(repo,
                "Tests/Fixtures/ProjectV3/project-v3-full.retouch"))))!;

        var v4Path = Path.Combine(repo, "Tests/Fixtures/ProjectV4/project-v4-full.retouch");
        using (var session = ProjectSession.Open(v4Path))
        {
            var model = session.Document;
            Check("a macOS v4 project opens on Windows", model.Version == 4);
            Check("the photo path comes from the project",
                  model.ImagePath == "/Users/owner/Photos/portrait-session-07.jpg");

            var crop = model.Crop ?? default;
            Check("the crop arrives as named geometry",
                  crop.X == 0.08 && crop.Y == 0.12
                  && crop.Width == 0.76 && crop.Height == 0.74);

            var orientation = model.Orientation;
            Check("the orientation arrives",
                  orientation.QuarterTurns == 1 && orientation.Flipped
                  && orientation.Angle == 3.5);
            Check("the adjustments arrive",
                  model.Adjustment("smooth") == 35 && model.Adjustment("contrast") == 12
                  && model.Adjustment("exposure") == 5);

            var savedPath = Path.Combine(root, "from-macos-v4.retouch");
            session.Save(savedPath);
            var saved = JsonNode.Parse(File.ReadAllText(savedPath))!;
            Check("a saved v4 project keeps every record",
                  JsonNode.DeepEquals(saved, v4Fixture));
            Check("an unknown top-level key survives the Windows save",
                  saved["futureFlag"]?.GetValue<string>() == "kept");
            Check("the required feature survives the Windows save",
                  saved["requiredFeatures"] is JsonArray features && features.Count == 1);

            model.SetAdjustment("exposure", 13);
            session.Save(savedPath);
            using var reopened = ProjectSession.Open(savedPath);
            Check("an edit on Windows reopens with the project",
                  reopened.Document.Adjustment("exposure") == 13);
            // The ABI returns the typed record; an unknown top-level key travels
            // in the write context, so it is proved by the next save, not by the
            // reopened document.
            var resavedPath = Path.Combine(root, "from-macos-v4-resaved.retouch");
            reopened.Save(resavedPath);
            var resaved = JsonNode.Parse(File.ReadAllText(resavedPath))!;
            Check("a reopened project keeps the unknown key on the next save",
                  resaved["futureFlag"]?.GetValue<string>() == "kept");
        }

        var v3Path = Path.Combine(repo, "Tests/Fixtures/ProjectV3/project-v3-full.retouch");
        using (var session = ProjectSession.Open(v3Path))
        {
            Check("a macOS v3 project opens as the current record",
                  session.Document.Version == 4);

            var savedPath = Path.Combine(root, "from-macos-v3.retouch");
            session.Save(savedPath);
            var saved = JsonNode.Parse(File.ReadAllText(savedPath))!;
            Check("a v3 project saves as v3", saved["version"]!.GetValue<int>() == 3);
            Check("a v3 save keeps the unkeyed geometry", saved["crop"] is JsonArray);
            Check("a v3 save keeps every record", JsonNode.DeepEquals(saved, v3Fixture));
        }
    }

    /// <summary>
    /// The checkout that holds the shared fixtures. `build-windows.ps1` runs the
    /// tests from the repository root; the upward search keeps a direct
    /// `dotnet run` from the test project working too.
    /// </summary>
    private static string RepoRoot()
    {
        var starts = new[]
        {
            Environment.GetEnvironmentVariable("RETOUCH_REPO_ROOT"),
            Directory.GetCurrentDirectory(),
            AppContext.BaseDirectory,
        };
        foreach (var start in starts)
        {
            if (string.IsNullOrEmpty(start))
            {
                continue;
            }
            for (var directory = new DirectoryInfo(start);
                 directory is not null;
                 directory = directory.Parent)
            {
                var marker = Path.Combine(directory.FullName,
                                          "Tests/Fixtures/ProjectV4/project-v4-full.retouch");
                if (File.Exists(marker))
                {
                    return directory.FullName;
                }
            }
        }
        throw new InvalidOperationException(
            "the shared project fixtures were not found; set RETOUCH_REPO_ROOT");
    }

    private static void Put(PixelBuffer buffer, int x, int y,
                            byte r = 0, byte g = 0, byte b = 0, byte a = 255)
    {
        var offset = (y * buffer.Width + x) * 4;
        buffer.Pixels[offset] = b;
        buffer.Pixels[offset + 1] = g;
        buffer.Pixels[offset + 2] = r;
        buffer.Pixels[offset + 3] = a;
    }

    private static (byte B, byte G, byte R, byte A) Get(PixelBuffer buffer, int x, int y)
    {
        var offset = (y * buffer.Width + x) * 4;
        return (buffer.Pixels[offset], buffer.Pixels[offset + 1],
                buffer.Pixels[offset + 2], buffer.Pixels[offset + 3]);
    }

    private static double Mean(PixelBuffer buffer)
    {
        long total = 0;
        for (var offset = 0; offset < buffer.Pixels.Length; offset += 4)
        {
            total += buffer.Pixels[offset] + buffer.Pixels[offset + 1]
                   + buffer.Pixels[offset + 2];
        }
        return total / (buffer.Pixels.Length / 4.0) / 3.0;
    }

    private static void Check(string name, bool condition)
    {
        if (condition)
        {
            Pass(name);
        }
        else
        {
            Fail(name, "condition was false");
        }
    }

    private static void Pass(string name)
    {
        _checks++;
        Console.WriteLine($"  ok {name}");
    }

    private static void Fail(string name, string detail)
    {
        _checks++;
        _failures++;
        Console.WriteLine($"  x {name}: {detail}");
    }
}
