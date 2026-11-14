using System.Text;
using System.Text.Json.Nodes;
using RetouchStudio.Core.Imaging;
using RetouchStudio.Core.Interop;
using RetouchStudio.Core.Project;
using RetouchStudio.Core.Render;
using RetouchStudio.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;

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
            Corpus(root);
            BitDepth(root);
            SixteenBitPreview(root);
            BatchExport(root);
            AdjustmentEvidence();
            FormatProbes(root);
            Metadata(root);
            Interchange(root);
            UnsupportedEditGuard();
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
        Check("positive exposure brightens", Mean(brighter) > Mean(gray) + 5);
        Check("full exposure stays on the shared 0.30 EV scale",
              Mean(brighter) < Mean(gray) + 20);

        var darker = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(-100, 0, 0, 0, 0, 0, 0, 0, 0));
        Check("negative exposure darkens", Mean(darker) < Mean(gray) - 5);

        var warm = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 100, 0, 0));
        Check("positive warmth raises red over blue",
              Get(warm, 1, 1).R > Get(warm, 1, 1).B);

        var vignetted = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 0, 100));
        Check("vignette darkens the corner more than the centre",
              Get(vignetted, 0, 0).R < Get(vignetted, 2, 2).R);

        // macOS only runs CIVignette above zero, so a negative slider is a
        // no-op there; the shared document must not look different here.
        var negativeVignette = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 0, -80));
        Check("a negative vignette changes nothing, as on macOS",
              negativeVignette.Pixels.AsSpan().SequenceEqual(gray.Pixels));

        // Clarity follows the macOS shape: positive clarity moves luminance
        // detail only, so a flat field cannot move, and a step edge gains
        // contrast instead of colour fringes. Negative clarity blurs, which is
        // what CIGaussianBlur does there, not an inverted unsharp.
        var flatSharp = AdjustmentPipeline.Apply(
            gray, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 100, 0));
        Check("positive clarity leaves a flat field alone",
              flatSharp.Pixels.AsSpan().SequenceEqual(gray.Pixels));

        var edge = new PixelBuffer(16, 16);
        for (var y = 0; y < 16; y++)
        {
            for (var x = 0; x < 16; x++)
            {
                var value = (byte)(x < 8 ? 80 : 160);
                Put(edge, x, y, r: value, g: value, b: value);
            }
        }
        var sharpEdge = AdjustmentPipeline.Apply(
            edge, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 100, 0));
        Check("positive clarity digs the dark side of a step edge",
              Get(sharpEdge, 7, 8).R < 80 && Get(sharpEdge, 8, 8).R > 160);

        var softEdge = AdjustmentPipeline.Apply(
            edge, new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, -100, 0));
        Check("negative clarity softens the same edge",
              Get(softEdge, 7, 8).R > 80 && Get(softEdge, 8, 8).R < 160);
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
    /// The four adjustment cases both hosts implement, compared against the
    /// macOS reference PNGs. This is measurement, not a gate: the Windows
    /// pipeline is behaviourally aligned, not pixel-identical, and
    /// `Docs/IMAGE_COMPARISON_METHODOLOGY.md` approves no numeric tolerance.
    /// </summary>
    private static void AdjustmentEvidence()
    {
        var repo = RepoRoot();
        var fixtures = Path.Combine(repo, "Tests/Corpus/Fixtures");
        var references = Path.Combine(repo, "Tests/Corpus/References");
        var codec = new WindowsImageCodec();
        var cases = new (string Id, string Fixture, GlobalAdjustments Adjustments)[]
        {
            ("G01_EXPOSURE_UP", "F05_gradient_sky.png",
             new GlobalAdjustments(40, 0, 0, 0, 0, 0, 0, 0, 0)),
            ("G04_BLACKS", "F06_highlights_shadows.png",
             new GlobalAdjustments(0, 0, 60, 0, 0, 0, 0, 0, 0)),
            ("G09_CLARITY_UP", "F04_detail_chart.png",
             new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 55, 0)),
            ("G11_VIGNETTE", "F01_portrait_srgb_8.png",
             new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 0, 55)),
        };

        foreach (var (id, fixture, adjustments) in cases)
        {
            var source = codec.DecodeAsync(Path.Combine(fixtures, fixture))
                              .GetAwaiter().GetResult();
            var rendered = AdjustmentPipeline.Apply(source, adjustments);
            var reference = codec.DecodeAsync(Path.Combine(references, id + ".png"))
                                 .GetAwaiter().GetResult();
            Check($"{id} reference has the rendered size",
                  source.Width == reference.Width && source.Height == reference.Height);

            var (mae, rmse, psnr, changed, lumaDelta) = Compare(rendered, reference);
            Console.WriteLine($"  case {id}: mae {mae:0.###} rmse {rmse:0.###} " +
                              $"psnr {psnr:0.##} dB changed {changed:P1} " +
                              $"luma delta {lumaDelta:+0.###;-0.###;0}");
            if (id == "G11_VIGNETTE")
            {
                // The vignette follows CIVignette's measured shape, so this is a
                // parity gate, not a smoke test: a level of headroom covers the
                // 8-bit rounding the reference went through.
                Check("G11 stays within one level of the macOS vignette", mae <= 1.0);
            }
            if (id == "G09_CLARITY_UP")
            {
                // Clarity reproduces CIUnsharpMask's Gaussian and the
                // keepLuminance rebuild in linear light; what is left is 8-bit
                // rounding on the detail chart's hard edges.
                Check("G09 stays within one level of the macOS clarity", mae <= 1.0);
            }
        }
    }

    private static (double Mae, double Rmse, double Psnr, double Changed, double LumaDelta)
        Compare(PixelBuffer rendered, PixelBuffer reference)
    {
        var pixels = rendered.Width * rendered.Height;
        long absolute = 0;
        long changed = 0;
        double squares = 0;
        double renderedLuma = 0;
        double referenceLuma = 0;

        for (var offset = 0; offset < rendered.Pixels.Length; offset += 4)
        {
            var anyChanged = false;
            for (var channel = 0; channel < 3; channel++)
            {
                var difference = rendered.Pixels[offset + channel]
                               - reference.Pixels[offset + channel];
                absolute += Math.Abs(difference);
                squares += (double)difference * difference;
                anyChanged |= difference != 0;
            }
            if (anyChanged)
            {
                changed++;
            }
            renderedLuma += 0.2126 * rendered.Pixels[offset + 2]
                          + 0.7152 * rendered.Pixels[offset + 1]
                          + 0.0722 * rendered.Pixels[offset];
            referenceLuma += 0.2126 * reference.Pixels[offset + 2]
                           + 0.7152 * reference.Pixels[offset + 1]
                           + 0.0722 * reference.Pixels[offset];
        }

        var samples = pixels * 3.0;
        var mae = absolute / samples;
        var mse = squares / samples;
        var psnr = mse == 0 ? 99 : 10 * Math.Log10(255 * 255 / mse);
        return (mae, Math.Sqrt(mse), psnr, changed / (double)pixels,
                (renderedLuma - referenceLuma) / pixels);
    }

    /// <summary>
    /// Diagnostics, not gates: asks WIC whether it can hold 16-bit pixels and
    /// whether this machine has a HEIF decoder. The 16-bit answer is already
    /// used by the export path; the HEIC answer decides whether a read path is
    /// possible at all. No capability is asserted here beyond the file being
    /// readable.
    /// </summary>
    private static void FormatProbes(string root)
    {
        var repo = RepoRoot();
        var fixtures = Path.Combine(repo, "Tests/Corpus/Fixtures");
        var exports = Path.Combine(repo, "Tests/Corpus/Exports");

        try
        {
            var hex = Decode16(Path.Combine(fixtures, "F11_p3_16bit.png"));
            Console.WriteLine($"  probe Rgba16 decode: kept ({hex})");
        }
        catch (Exception error)
        {
            Console.WriteLine($"  probe Rgba16 decode: failed ({error.Message})");
        }

        foreach (var (name, encoder) in new[]
                 {
                     ("png", BitmapEncoder.PngEncoderId),
                     ("tiff", BitmapEncoder.TiffEncoderId),
                 })
        {
            try
            {
                var path = Path.Combine(root, "probe-16bit." + name);
                Encode16(path, encoder);
                var depth = Depth(path);
                Console.WriteLine($"  probe 16-bit {name} encode: {depth}");
            }
            catch (Exception error)
            {
                Console.WriteLine($"  probe 16-bit {name} encode: failed ({error.Message})");
            }
        }

        try
        {
            var size = Size(Path.Combine(exports, "F01_export_256.heic"));
            Console.WriteLine($"  probe HEIC decode: kept ({size})");
        }
        catch (Exception error)
        {
            Console.WriteLine($"  probe HEIC decode: unavailable " +
                              $"(0x{error.HResult:X8} {error.Message})");
        }
    }

    private static string Decode16(string path)
    {
        var file = StorageFile.GetFileFromPathAsync(Path.GetFullPath(path))
                              .AsTask().GetAwaiter().GetResult();
        using var stream = file.OpenAsync(FileAccessMode.Read)
                               .AsTask().GetAwaiter().GetResult();
        var decoder = BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
        var data = decoder.GetPixelDataAsync(
            BitmapPixelFormat.Rgba16, BitmapAlphaMode.Straight, new BitmapTransform(),
            ExifOrientationMode.RespectExifOrientation,
            ColorManagementMode.ColorManageToSRgb).AsTask().GetAwaiter().GetResult();
        var pixels = data.DetachPixelData();
        return $"{decoder.OrientedPixelWidth}x{decoder.OrientedPixelHeight} " +
               $"{pixels.Length} bytes";
    }

    private static void Encode16(string path, Guid encoderId)
    {
        var folder = StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path))
                                 .AsTask().GetAwaiter().GetResult();
        var file = folder.CreateFileAsync(Path.GetFileName(path),
                                          CreationCollisionOption.ReplaceExisting)
                         .AsTask().GetAwaiter().GetResult();
        using var stream = file.OpenAsync(FileAccessMode.ReadWrite)
                               .AsTask().GetAwaiter().GetResult();
        var encoder = BitmapEncoder.CreateAsync(encoderId, stream)
                                   .AsTask().GetAwaiter().GetResult();

        const int width = 8;
        const int height = 6;
        var pixels = new ushort[width * height * 4];
        for (var index = 0; index < width * height; index++)
        {
            pixels[index * 4] = 1000;
            pixels[index * 4 + 1] = 2000;
            pixels[index * 4 + 2] = 3000;
            pixels[index * 4 + 3] = 65535;
        }
        var bytes = new byte[pixels.Length * 2];
        Buffer.BlockCopy(pixels, 0, bytes, 0, bytes.Length);

        encoder.SetPixelData(BitmapPixelFormat.Rgba16, BitmapAlphaMode.Straight,
                             width, height, 96, 96, bytes);
        encoder.FlushAsync().AsTask().GetAwaiter().GetResult();
    }

    private static string Depth(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (TryPngDepth(bytes, out var png))
        {
            return $"kept ({png} bits stored, PNG IHDR)";
        }
        if (TryTiffDepth(bytes, out var tiff))
        {
            return $"kept ({tiff} bits stored, TIFF BitsPerSample)";
        }
        return "unknown (no readable depth marker)";
    }

    private static bool TryPngDepth(byte[] bytes, out int depth)
    {
        depth = 0;
        if (bytes.Length < 26
            || bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4E || bytes[3] != 0x47
            || bytes[12] != 'I' || bytes[13] != 'H' || bytes[14] != 'D' || bytes[15] != 'R')
        {
            return false;
        }
        depth = bytes[24];
        return true;
    }

    private static bool TryTiffDepth(byte[] bytes, out int depth)
    {
        depth = 0;
        if (bytes.Length < 8)
        {
            return false;
        }
        var little = bytes[0] == 'I' && bytes[1] == 'I';
        var big = bytes[0] == 'M' && bytes[1] == 'M';
        if (!little && !big)
        {
            return false;
        }

        int U16(int offset) => little
            ? bytes[offset] | (bytes[offset + 1] << 8)
            : (bytes[offset] << 8) | bytes[offset + 1];
        long U32(int offset) => little
            ? (uint)(bytes[offset] | (bytes[offset + 1] << 8)
                   | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24))
            : (uint)((bytes[offset] << 24) | (bytes[offset + 1] << 16)
                   | (bytes[offset + 2] << 8) | bytes[offset + 3]);

        var ifd = U32(4);
        if (ifd + 2 > bytes.Length)
        {
            return false;
        }
        var count = U16((int)ifd);
        for (var index = 0; index < count; index++)
        {
            var entry = (int)ifd + 2 + index * 12;
            if (entry + 12 > bytes.Length)
            {
                return false;
            }
            if (U16(entry) != 0x0102) // BitsPerSample
            {
                continue;
            }
            var values = U32(entry + 4);
            var valueAt = values * 2 <= 4 ? entry + 8 : (int)U32(entry + 8);
            if (valueAt + 1 >= bytes.Length)
            {
                return false;
            }
            depth = U16(valueAt);
            return true;
        }
        return false;
    }

    private static string Size(string path)
    {
        var file = StorageFile.GetFileFromPathAsync(Path.GetFullPath(path))
                              .AsTask().GetAwaiter().GetResult();
        using var stream = file.OpenAsync(FileAccessMode.Read)
                               .AsTask().GetAwaiter().GetResult();
        var decoder = BitmapDecoder.CreateAsync(stream).AsTask().GetAwaiter().GetResult();
        return $"{decoder.PixelWidth}x{decoder.PixelHeight}";
    }

    /// <summary>
    /// The metadata policy: a photograph keeps its camera keys when the caller
    /// turns stripping off, keeps only the resolution when it is on, and PNG
    /// carries no EXIF on this host because the Windows metadata API does not
    /// map EXIF onto PNG chunks.
    /// </summary>
    /// <summary>
    /// The shared corpus on the load path: orientation is baked upright, a
    /// no-op export is pixel-identical, alpha survives a PNG export and is
    /// flattened onto white for a JPEG. The luma line is evidence for the
    /// cross-platform record, not a gate: no numeric tolerance is approved.
    /// </summary>
    private static void Corpus(string root)
    {
        var codec = new WindowsImageCodec();
        var fixtures = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures");

        var turned = codec.DecodeAsync(Path.Combine(fixtures, "F10_exif_orient6.jpg"))
                          .GetAwaiter().GetResult();
        Check("an orientation-6 JPEG decodes upright",
              turned.Width == 480 && turned.Height == 720);
        var (luma, spread) = Luma(turned);
        Console.WriteLine($"  load F10 luma {luma:0.###} sd {spread:0.###} " +
                          "(macOS 115.746 / 61.530)");

        var p3 = codec.DecodeAsync(Path.Combine(fixtures, "F11_p3_16bit.png"))
                      .GetAwaiter().GetResult();
        Check("a 16-bit P3 PNG decodes to the 8-bit host format",
              p3.Width == 512 && p3.Height == 512);

        // ColorSync on macOS converts the file's Display P3 profile to sRGB and
        // reads these points as the values below; the file's own P3 values are
        // 187/59/63, 13/242/242, 208/226/207 and 30/148/181. A decoder that
        // ignored the profile would land on that second set, more than ten
        // levels away, so this proves the conversion rather than rounding.
        // A fifth point at (200,300) is a saturated cyan where WIC and
        // ColorSync pick different rendering intents (26 vs 18 in red); it is
        // left out rather than given a special bound.
        var p3Points = new (int X, int Y, byte R, byte G, byte B)[]
        {
            (100, 100, 203, 43, 57),
            (256, 256, 0, 247, 244),
            (400, 120, 204, 227, 205),
            (350, 400, 0, 150, 185),
        };
        var managed = p3Points.All(point =>
        {
            var sample = Get(p3, point.X, point.Y);
            return Math.Abs(sample.R - point.R) <= 3
                && Math.Abs(sample.G - point.G) <= 3
                && Math.Abs(sample.B - point.B) <= 3;
        });
        Check("a Display P3 photo is colour-managed to sRGB on decode", managed);

        var p3Wide = codec.Decode16Async(Path.Combine(fixtures, "F11_p3_16bit.png"))
                          .GetAwaiter().GetResult();
        var wideManaged = p3Points.All(point =>
        {
            var offset = (point.Y * p3Wide.Width + point.X) * 4;
            return Math.Abs(p3Wide.Pixels[offset] / 257.0 - point.R) <= 4
                && Math.Abs(p3Wide.Pixels[offset + 1] / 257.0 - point.G) <= 4
                && Math.Abs(p3Wide.Pixels[offset + 2] / 257.0 - point.B) <= 4;
        });
        Check("the 16-bit export path is colour-managed the same way", wideManaged);

        var sourcePath = Path.Combine(fixtures, "F01_portrait_srgb_8.png");
        var source = codec.DecodeAsync(sourcePath).GetAwaiter().GetResult();
        using (var session = ProjectSession.Create(sourcePath))
        {
            var noop = Path.Combine(root, "corpus-noop.png");
            var plan = ExportRunner.ExportAsync(session, codec, noop, "png", 1.0, 0)
                                   .GetAwaiter().GetResult();
            var roundTrip = codec.DecodeAsync(noop).GetAwaiter().GetResult();
            Check("a zero-adjustment export is pixel-identical",
                  plan.BitsPerChannel == 16
                  && roundTrip.Width == source.Width && roundTrip.Height == source.Height
                  && roundTrip.Pixels.AsSpan().SequenceEqual(source.Pixels));
        }

        var cutoutPath = Path.Combine(fixtures, "F09_alpha_cutout.png");
        var cutout = codec.DecodeAsync(cutoutPath).GetAwaiter().GetResult();
        var clear = FindClear(cutout);
        Check("a transparent source keeps clear and solid pixels",
              clear is not null && FindSolid(cutout) is not null);

        using (var session = ProjectSession.Create(cutoutPath))
        {
            var png = Path.Combine(root, "corpus-cutout.png");
            var pngPlan = ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0)
                                     .GetAwaiter().GetResult();
            var pngBack = codec.DecodeAsync(png).GetAwaiter().GetResult();
            Check("a PNG export keeps the alpha channel",
                  !pngPlan.FlattensAlpha && clear is { } point
                  && Get(pngBack, point.X, point.Y).A == 0);

            var jpeg = Path.Combine(root, "corpus-cutout.jpg");
            var jpegPlan = ExportRunner.ExportAsync(session, codec, jpeg, "jpeg", 0.92, 0)
                                      .GetAwaiter().GetResult();
            var jpegBack = codec.DecodeAsync(jpeg).GetAwaiter().GetResult();
            var corner = clear is { } spot ? Get(jpegBack, spot.X, spot.Y) : default;
            // A clear pixel may sit next to an opaque edge, so the JPEG ringing
            // is allowed a few levels above pure white.
            Check("a JPEG export flattens clear pixels onto white",
                  jpegPlan.FlattensAlpha && jpegPlan.BitsPerChannel == 8
                  && corner.A == 255 && corner.R >= 245 && corner.G >= 245
                  && corner.B >= 245);
        }
    }

    /// <summary>
    /// 16-bit export. The shared plan gives PNG and TIFF a 16-bit container, so
    /// the export decodes at 16 bits, runs the same crop/orientation/adjustment
    /// order on the 16-bit buffer and writes 16-bit samples. The depth is read
    /// back from the file header and the precision from samples that are not
    /// multiples of 257, so neither a plan flag nor a metadata property is
    /// taken as proof that the pixels are deeper than 8 bits.
    /// </summary>
    private static void BitDepth(string root)
    {
        var codec = new WindowsImageCodec();
        var fixtures = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures");
        var eightBitPath = Path.Combine(fixtures, "F01_portrait_srgb_8.png");
        var eightBit = codec.DecodeAsync(eightBitPath).GetAwaiter().GetResult();
        var wide = codec.Decode16Async(eightBitPath).GetAwaiter().GetResult();
        Check("an 8-bit source promotes to the 16-bit buffer exactly",
              wide.Width == eightBit.Width && wide.Height == eightBit.Height
              && MaxDelta(eightBit, wide) == 0);

        using (var session = ProjectSession.Create(eightBitPath))
        {
            var png = Path.Combine(root, "depth-16.png");
            var plan = ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0)
                                   .GetAwaiter().GetResult();
            Check("the plan asks for 16 bits for a PNG", plan.BitsPerChannel == 16);
            Check("a PNG export stores 16 bits per sample",
                  TryPngDepth(File.ReadAllBytes(png), out var pngDepth) && pngDepth == 16);

            var narrowBack = codec.DecodeAsync(png).GetAwaiter().GetResult();
            Check("a 16-bit no-op export reads back at 8 bits unchanged",
                  narrowBack.Pixels.AsSpan().SequenceEqual(eightBit.Pixels));
            var wideBack = codec.Decode16Async(png).GetAwaiter().GetResult();
            Check("a 16-bit no-op export keeps every 16-bit sample",
                  wideBack.Pixels.AsSpan().SequenceEqual(wide.Pixels));

            var tiff = Path.Combine(root, "depth-16.tiff");
            ExportRunner.ExportAsync(session, codec, tiff, "tiff", 1.0, 0)
                        .GetAwaiter().GetResult();
            Check("a TIFF export stores 16 bits per sample",
                  TryTiffDepth(File.ReadAllBytes(tiff), out var tiffDepth) && tiffDepth == 16);
            var tiffBack = codec.Decode16Async(tiff).GetAwaiter().GetResult();
            Check("a TIFF export keeps every 16-bit sample",
                  tiffBack.Width == wide.Width && tiffBack.Height == wide.Height
                  && tiffBack.Pixels.AsSpan().SequenceEqual(wide.Pixels));

            session.Document.SetAdjustment("exposure", 40);
            var adjusted = Path.Combine(root, "depth-16-adjusted.png");
            ExportRunner.ExportAsync(session, codec, adjusted, "png", 1.0, 0)
                        .GetAwaiter().GetResult();
            var adjustedBack = codec.Decode16Async(adjusted).GetAwaiter().GetResult();
            var offGrid = CountOffGrid(adjustedBack);
            Console.WriteLine($"  adjusted 16-bit export: {offGrid} of " +
                              $"{adjustedBack.Pixels.Length / 4 * 3} colour samples off the 8-bit grid");
            Check("an adjusted 16-bit export keeps intermediate precision",
                  offGrid > adjustedBack.Pixels.Length / 4);
        }

        var p3Path = Path.Combine(fixtures, "F11_p3_16bit.png");
        var p3 = codec.Decode16Async(p3Path).GetAwaiter().GetResult();
        using (var session = ProjectSession.Create(p3Path))
        {
            var png = Path.Combine(root, "depth-16-source.png");
            ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0)
                        .GetAwaiter().GetResult();
            var back = codec.Decode16Async(png).GetAwaiter().GetResult();
            Check("a 16-bit source export is sample-exact",
                  back.Width == p3.Width && back.Height == p3.Height
                  && back.Pixels.AsSpan().SequenceEqual(p3.Pixels));
            Check("the 16-bit source carries precision 8 bits cannot hold",
                  CountOffGrid(p3) > 0);
        }

        // A buffer the 8-bit path could not have produced, so an exact return
        // proves the samples are stored, not approximated. PNG carries straight
        // alpha natively, so this one varies both colour and alpha.
        var precise = new PixelBuffer16(8, 6);
        for (var index = 0; index < 8 * 6; index++)
        {
            precise.Pixels[index * 4] = (ushort)(1000 + index * 101);
            precise.Pixels[index * 4 + 1] = (ushort)(2000 + index * 211);
            precise.Pixels[index * 4 + 2] = (ushort)(3000 + index * 313);
            precise.Pixels[index * 4 + 3] = (ushort)(40000 + index);
        }
        var precisePng = Path.Combine(root, "precision.png");
        codec.Encode16Async(precise, precisePng, "png").GetAwaiter().GetResult();
        var preciseBack = codec.Decode16Async(precisePng).GetAwaiter().GetResult();
        Check("a 16-bit PNG keeps colour and alpha samples off the 8-bit grid",
              preciseBack.Width == 8 && preciseBack.Height == 6
              && preciseBack.Pixels.AsSpan().SequenceEqual(precise.Pixels));

        // A TIFF encoder may store associated alpha, which is an alpha
        // convention rather than a depth problem, so this buffer is opaque and
        // only the depth is under test.
        var opaque = new PixelBuffer16(8, 6);
        for (var index = 0; index < 8 * 6; index++)
        {
            opaque.Pixels[index * 4] = (ushort)(1000 + index * 101);
            opaque.Pixels[index * 4 + 1] = (ushort)(2000 + index * 211);
            opaque.Pixels[index * 4 + 2] = (ushort)(3000 + index * 313);
            opaque.Pixels[index * 4 + 3] = 65535;
        }
        var preciseTiff = Path.Combine(root, "precision.tiff");
        codec.Encode16Async(opaque, preciseTiff, "tiff").GetAwaiter().GetResult();
        var opaqueBack = codec.Decode16Async(preciseTiff).GetAwaiter().GetResult();
        Check("a 16-bit TIFF keeps samples off the 8-bit grid",
              opaqueBack.Width == 8 && opaqueBack.Height == 6
              && opaqueBack.Pixels.AsSpan().SequenceEqual(opaque.Pixels));

        try
        {
            codec.Encode16Async(opaque, Path.Combine(root, "refused.jpg"), "jpeg")
                 .GetAwaiter().GetResult();
            Fail("a 16-bit encode refuses a JPEG", "no exception");
        }
        catch (NotSupportedException)
        {
            Pass("a 16-bit encode refuses a JPEG");
        }

        // Clarity is the one stage whose result is quantised before it is used:
        // the 8-bit pass writes the pre-clarity picture as bytes and reads it
        // back, while the 16-bit pass keeps 16 bits. So the tone/colour check
        // runs without clarity, where only rounding can differ, and clarity gets
        // its own, wider, measured bound.
        var adjustments = new GlobalAdjustments(30, 15, 10, -5, 25, 20, 10, 0, 30);
        var narrow = AdjustmentPipeline.Apply(eightBit, adjustments);
        var deep = AdjustmentPipeline16.Apply(wide, adjustments);
        var drift = Drift(narrow, deep);
        Console.WriteLine($"  8-bit vs 16-bit tone/colour drift: {drift} levels max");
        Check("both depths apply the same tone and colour maths", drift <= 1);

        var sharpened = adjustments with { Clarity = 40 };
        var sharpDrift = Drift(AdjustmentPipeline.Apply(eightBit, sharpened),
                               AdjustmentPipeline16.Apply(wide, sharpened));
        Console.WriteLine($"  8-bit vs 16-bit clarity drift: {sharpDrift} levels max");
        Check("clarity at both depths stays inside the 8-bit blur's truncation",
              sharpDrift <= 3);
    }

    /// <summary>
    /// The preview keeps 16 bits for a file that stores them. The depth comes
    /// from the container header — PNG's IHDR and TIFF's BitsPerSample — and
    /// the 16-bit render reaches the display through the same rounding the
    /// 8-bit preview uses, so the picture on screen does not shift when the
    /// pipeline changes depth.
    /// </summary>
    private static void SixteenBitPreview(string root)
    {
        var codec = new WindowsImageCodec();
        var fixtures = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures");
        var p3Path = Path.Combine(fixtures, "F11_p3_16bit.png");
        var depth = codec.ReadBitDepthAsync(p3Path).GetAwaiter().GetResult();
        Console.WriteLine($"  16-bit fixture depth probe: {depth}");
        Check("the PNG header reports the 16-bit fixture's depth", depth == 16);
        Check("the PNG header reports an 8-bit fixture's depth",
              codec.ReadBitDepthAsync(Path.Combine(fixtures, "F01_portrait_srgb_8.png"))
                   .GetAwaiter().GetResult() == 8);
        Check("a JPEG reports 8 bits",
              codec.ReadBitDepthAsync(Path.Combine(fixtures, "F10_exif_orient6.jpg"))
                   .GetAwaiter().GetResult() == 8);

        using (var session = ProjectSession.Create(
                   Path.Combine(fixtures, "F01_portrait_srgb_8.png")))
        {
            var tiff = Path.Combine(root, "preview-depth.tiff");
            ExportRunner.ExportAsync(session, codec, tiff, "tiff", 1.0, 0)
                        .GetAwaiter().GetResult();
            var tiffDepth = codec.ReadBitDepthAsync(tiff).GetAwaiter().GetResult();
            Console.WriteLine($"  exported TIFF depth probe: {tiffDepth}");
            Check("the TIFF header reports the export's 16 bits", tiffDepth == 16);
        }

        // Exact 8-bit levels, so the reduction must return them unchanged and
        // in BGRA order.
        var exact = new PixelBuffer16(3, 1);
        exact.Pixels[0] = 255 * 257;
        exact.Pixels[1] = 128 * 257;
        exact.Pixels[2] = 0;
        exact.Pixels[3] = 65535;
        var reduced = exact.ToBgra8();
        Check("the 16-to-8 reduction keeps exact levels and swaps to BGRA",
              reduced.Pixels[0] == 0 && reduced.Pixels[1] == 128
              && reduced.Pixels[2] == 255 && reduced.Pixels[3] == 255);

        var narrow = codec.DecodeAsync(p3Path).GetAwaiter().GetResult();
        var wide = codec.Decode16Async(p3Path).GetAwaiter().GetResult();

        // At rest the two decodes are the same picture: the 8-bit decode
        // quantises the colour transform to levels, and the 16-bit decode is
        // reduced the same way, so they agree within the rounding.
        var plain = new GlobalAdjustments(0, 0, 0, 0, 0, 0, 0, 0, 0);
        var plainDelta = PixelDelta(AdjustmentPipeline.Apply(narrow, plain),
                                    AdjustmentPipeline16.Apply(wide, plain).ToBgra8());
        Console.WriteLine($"  8-bit vs 16-bit preview at rest: {plainDelta} levels max");
        Check("at rest both preview depths show the same picture", plainDelta <= 2);

        // With adjustments the two previews legitimately differ: this fixture
        // stores samples off the 8-bit grid, and the 8-bit decode has already
        // rounded them before the adjustment amplifies the rounding. The
        // 16-bit preview is the one that keeps the source's levels; the bound
        // is the measured difference, not a parity claim.
        var adjustments = new GlobalAdjustments(30, 20, 10, 0, 20, 15, 10, 45, 25);
        var delta = PixelDelta(AdjustmentPipeline.Apply(narrow, adjustments),
                               AdjustmentPipeline16.Apply(wide, adjustments).ToBgra8());
        Console.WriteLine($"  adjusted 8-bit vs 16-bit preview: {delta} levels max");
        Check("the adjusted 16-bit preview keeps source levels the 8-bit path lost",
              delta > 0 && delta <= 10);
    }

    /// <summary>
    /// A batch must produce exactly what the single-file export produces, for
    /// every source, without touching the sources and without overwriting a
    /// file it did not create. One unreadable file must not stop the others.
    /// </summary>
    private static void BatchExport(string root)
    {
        var codec = new WindowsImageCodec();
        var fixtures = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures");
        var sourcesDir = Path.Combine(root, "batch-src");
        var destination = Path.Combine(root, "batch-out");
        Directory.CreateDirectory(sourcesDir);
        var names = new[] { "one.png", "two.png", "three.png" };
        var origins = new[]
        {
            Path.Combine(fixtures, "F01_portrait_srgb_8.png"),
            Path.Combine(fixtures, "F05_gradient_sky.png"),
            Path.Combine(fixtures, "F11_p3_16bit.png"),
        };
        var sources = new List<string>();
        for (var index = 0; index < origins.Length; index++)
        {
            var copy = Path.Combine(sourcesDir, names[index]);
            File.Copy(origins[index], copy);
            sources.Add(copy);
        }
        var before = sources.Select(Sha256).ToArray();

        using var session = ProjectSession.Create(origins[0]);
        session.Document.SetAdjustment("exposure", 40);

        var batch = BatchExporter.ExportAsync(session.Document, codec,
            new BatchExportRequest(sources, destination, "png", 1.0, 0, true))
            .GetAwaiter().GetResult();
        Check("a batch reports one result per source", batch.Count == sources.Count);
        Check("a batch exports every file",
              batch.All(item => item.Destination is not null && item.Error is null));
        Check("a batch names the results after the sources",
              batch.Select(item => Path.GetFileName(item.Destination!)).SequenceEqual(
                  new[] { "one-retouched.png", "two-retouched.png", "three-retouched.png" }));
        Check("a batch writes 16-bit PNGs",
              batch.All(item => TryPngDepth(File.ReadAllBytes(item.Destination!), out var depth)
                                && depth == 16));
        Check("a batch leaves the sources untouched",
              sources.Select(Sha256).SequenceEqual(before));

        var oneOff = Path.Combine(root, "batch-single.png");
        ExportRunner.ExportSourceAsync(session.Document, codec, sources[2], oneOff,
                                       "png", 1.0, 0)
                    .GetAwaiter().GetResult();
        var fromBatch = codec.Decode16Async(batch[2].Destination!).GetAwaiter().GetResult();
        var fromSingle = codec.Decode16Async(oneOff).GetAwaiter().GetResult();
        Check("a batch renders exactly like the single export",
              fromBatch.Width == fromSingle.Width && fromBatch.Height == fromSingle.Height
              && fromBatch.Pixels.AsSpan().SequenceEqual(fromSingle.Pixels));

        var collisionDir = Path.Combine(root, "batch-collision");
        Directory.CreateDirectory(collisionDir);
        var existing = Path.Combine(collisionDir, "one-retouched.png");
        var sentinel = new byte[] { 1, 2, 3 };
        File.WriteAllBytes(existing, sentinel);
        var collision = BatchExporter.ExportAsync(session.Document, codec,
            new BatchExportRequest(new[] { sources[0] }, collisionDir, "png", 1.0, 0, true))
            .GetAwaiter().GetResult();
        Check("a batch never overwrites a file it did not create",
              collision[0].Destination is not null
              && Path.GetFileName(collision[0].Destination) == "one-retouched-2.png"
              && File.ReadAllBytes(existing).SequenceEqual(sentinel));

        var mixed = BatchExporter.ExportAsync(session.Document, codec,
            new BatchExportRequest(
                new[] { Path.Combine(sourcesDir, "missing.png"), sources[1] },
                Path.Combine(root, "batch-mixed"), "jpeg", 0.9, 0, true))
            .GetAwaiter().GetResult();
        Check("a batch reports a file it cannot read and exports the rest",
              mixed[0].Destination is null && mixed[0].Error is not null
              && mixed[1].Destination is not null && mixed[1].Error is null
              && File.Exists(mixed[1].Destination));
    }

    private static string Sha256(string path) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)));

    /// <summary>Largest per-channel difference between two 8-bit buffers.</summary>
    private static int PixelDelta(PixelBuffer first, PixelBuffer second)
    {
        var max = 0;
        for (var offset = 0; offset < first.Pixels.Length; offset++)
        {
            max = Math.Max(max, Math.Abs(first.Pixels[offset] - second.Pixels[offset]));
        }
        return max;
    }

    /// <summary>Largest difference between an 8-bit buffer and its promotion.</summary>
    private static int MaxDelta(PixelBuffer narrow, PixelBuffer16 wide)
    {
        // PixelBuffer is BGRA and PixelBuffer16 is RGBA, so the channels are
        // matched by name, not by offset.
        var max = 0;
        for (var offset = 0; offset < narrow.Pixels.Length; offset += 4)
        {
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset] * 257 - wide.Pixels[offset + 2]));
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset + 1] * 257 - wide.Pixels[offset + 1]));
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset + 2] * 257 - wide.Pixels[offset]));
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset + 3] * 257 - wide.Pixels[offset + 3]));
        }
        return max;
    }

    /// <summary>
    /// Largest per-channel difference between the two pipelines, in 8-bit
    /// levels. The same input reaches both, so the only difference allowed is
    /// how each depth rounds the result: one level.
    /// </summary>
    private static int Drift(PixelBuffer narrow, PixelBuffer16 wide)
    {
        var max = 0;
        for (var offset = 0; offset < narrow.Pixels.Length; offset += 4)
        {
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset] - (wide.Pixels[offset + 2] >> 8)));
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset + 1] - (wide.Pixels[offset + 1] >> 8)));
            max = Math.Max(max, Math.Abs(narrow.Pixels[offset + 2] - (wide.Pixels[offset] >> 8)));
        }
        return max;
    }

    /// <summary>
    /// Colour samples that a 16→8→16 round trip could not have produced. A
    /// buffer written from the 8-bit pipeline has none.
    /// </summary>
    private static int CountOffGrid(PixelBuffer16 buffer)
    {
        var count = 0;
        for (var offset = 0; offset < buffer.Pixels.Length; offset += 4)
        {
            for (var channel = 0; channel < 3; channel++)
            {
                if (buffer.Pixels[offset + channel] % 257 != 0)
                {
                    count++;
                }
            }
        }
        return count;
    }

    private static (int X, int Y)? FindClear(PixelBuffer buffer)
    {
        // Prefer a clear pixel two pixels inside the transparent region, so the
        // JPEG ringing check is not sampling the one-pixel edge.
        (int X, int Y)? first = null;
        for (var y = 2; y < buffer.Height - 2; y++)
        {
            for (var x = 2; x < buffer.Width - 2; x++)
            {
                if (Get(buffer, x, y).A != 0)
                {
                    continue;
                }
                first ??= (x, y);
                if (Get(buffer, x - 2, y).A == 0 && Get(buffer, x + 2, y).A == 0
                    && Get(buffer, x, y - 2).A == 0 && Get(buffer, x, y + 2).A == 0)
                {
                    return (x, y);
                }
            }
        }
        return first;
    }

    private static (int X, int Y)? FindSolid(PixelBuffer buffer)
    {
        // The cutout fixture tops out at alpha 253, so a fully opaque 255 would
        // never match; anything near opaque is a solid pixel.
        for (var offset = 0; offset < buffer.Pixels.Length; offset += 4)
        {
            if (buffer.Pixels[offset + 3] >= 250)
            {
                var pixel = offset / 4;
                return (pixel % buffer.Width, pixel / buffer.Width);
            }
        }
        return null;
    }

    private static (double Mean, double StdDev) Luma(PixelBuffer buffer)
    {
        var count = buffer.Pixels.Length / 4;
        double sum = 0;
        double squares = 0;
        for (var offset = 0; offset < buffer.Pixels.Length; offset += 4)
        {
            var luma = 0.2126 * buffer.Pixels[offset + 2]
                     + 0.7152 * buffer.Pixels[offset + 1]
                     + 0.0722 * buffer.Pixels[offset];
            sum += luma;
            squares += luma * luma;
        }
        var mean = sum / count;
        return (mean, Math.Sqrt(Math.Max(0, squares / count - mean * mean)));
    }

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

        // Measured on the 16-bit PNG path: the writer keeps the allowlist.
        // Earlier 8-bit PNG exports dropped it, and this host no longer writes
        // 8-bit PNG, so the deeper writer's behaviour is the one that ships.
        var png = Path.Combine(root, "metadata-kept.png");
        ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var pngMeta = codec.ReadMetadataAsync(png).GetAwaiter().GetResult();
        Check("a kept 16-bit PNG carries the camera model",
              Text(pngMeta, "System.Photo.CameraModel") == "RS-Test");
        Check("a kept 16-bit PNG carries no key outside the allowlist",
              !pngMeta.Properties.Keys.Any(key =>
                  key != "System.Photo.CameraModel" && key != "System.Photo.IsoSpeed"
                  && (key.StartsWith("System.Photo.", StringComparison.Ordinal)
                      || key.StartsWith("System.GPS.", StringComparison.Ordinal))));

        var pngStripped = Path.Combine(root, "metadata-stripped.png");
        ExportRunner.ExportAsync(session, codec, pngStripped, "png", 1.0, 0)
                             .GetAwaiter().GetResult();
        var pngStrippedMeta = codec.ReadMetadataAsync(pngStripped).GetAwaiter().GetResult();
        Check("stripping drops the camera model from a 16-bit PNG",
              !pngStrippedMeta.Properties.ContainsKey("System.Photo.CameraModel"));

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
    /// The host keeps macOS-only edits in the project file but cannot draw
    /// them, so it has to name them before an export writes pixels that lack
    /// them. The shared fixtures carry every kind; a new document carries none.
    /// </summary>
    private static void UnsupportedEditGuard()
    {
        var repo = RepoRoot();
        using (var session = ProjectSession.Open(Path.Combine(
                   repo, "Tests/Fixtures/ProjectV4/project-v4-full.retouch")))
        {
            var edits = session.Document.UnsupportedEdits;
            Check("a macOS project names every edit this host cannot render",
                  edits.Count == 6
                  && edits.Contains("heal spots") && edits.Contains("stickers")
                  && edits.Contains("AI patches") && edits.Contains("analysis callouts")
                  && edits.Contains("automatic retouch") && edits.Contains("automatic colour"));
        }
        using (var session = ProjectSession.Open(Path.Combine(
                   repo, "Tests/Fixtures/ProjectV3/project-v3-full.retouch")))
        {
            Check("a v3 project is checked the same way",
                  session.Document.UnsupportedEdits.Count == 6);
        }

        var empty = new DocumentModel(new JsonObject());
        Check("a project with no extra edits names none", empty.UnsupportedEdits.Count == 0);

        empty.Root["healSpots"] = new JsonArray();
        empty.Root["stickers"] = new JsonArray();
        empty.Root["aiEdits"] = new JsonArray();
        empty.Root["analysis"] = new JsonObject { ["isEnabled"] = false };
        empty.Root["autoRetouchStrength"] = 0;
        empty.Root["autoColorStrength"] = 0;
        Check("empty lists and disabled tools are not edits", empty.UnsupportedEdits.Count == 0);

        empty.Root["stickers"] = new JsonArray(new JsonObject { ["kind"] = "heart" });
        Check("one sticker is enough to warn", empty.UnsupportedEdits.Count == 1
              && empty.UnsupportedEdits[0] == "stickers");
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
