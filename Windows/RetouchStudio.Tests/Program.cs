using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using RetouchStudio.App;
using RetouchStudio.Core.Imaging;
using RetouchStudio.Core.Interop;
using RetouchStudio.Core.IO;
using RetouchStudio.Core.Project;
using RetouchStudio.Core.Render;
using RetouchStudio.Core.View;
using RetouchStudio.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage;
using IRandomAccessStream = Windows.Storage.Streams.IRandomAccessStream;
// UseWPF replaces the SDK's implicit usings and drops System.IO, and
// Windows.Storage brings its own FileAttributes (no Hidden), so the two are
// named explicitly here.
using FileAttributes = System.IO.FileAttributes;

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
            CropGestures();
            Pixels();
            Adjustments();
            Codec(root);
            Export(root);
            Corpus(root);
            BitDepth(root);
            SixteenBitPreview(root);
            BatchExport(root);
            AtomicExport(root);
            ExportCancellation(root);
            ExportDestination(root);
            ExportRefusals(root);
            ExportDeniedByAcl(root);
            StaleSweep(root);
            AdjustmentEvidence();
            GeometryEvidence();
            FormatProbes(root);
            Metadata(root);
            Carry(root);
            CarryTransforms(root);
            Compose(root);
            Colour(root);
            Interchange(root);
            Recovery(root);
            RecoveryWriteFailures(root);
            ProjectSaveFailures(root);
            ExportExclusion(root);
            PerformanceAndStress(root);
            UnsupportedEditGuard(root);
            CropPresets();
            OrientationComposition();
            GeometryRenderParity();
            Histogram();
            CanvasZoom();
            CompareSplitChecks();
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

    /// <summary>
    /// The crop overlay's arithmetic: where the displayed photo sits, and what
    /// each drag does. The drag rules keep the frame inside the photo and keep
    /// the two sides from crossing.
    /// </summary>
    private static void CropGestures()
    {
        var wide = CropGeometry.Fit(800, 400, 800, 600);
        Check("a wide photo letterboxes in the preview box",
              wide.X == 0 && Math.Abs(wide.Y - 100) < 1e-9
              && wide.Width == 800 && wide.Height == 400);
        var tall = CropGeometry.Fit(400, 800, 800, 600);
        Check("a tall photo pillarboxes in the preview box",
              Math.Abs(tall.X - 250) < 1e-9 && tall.Y == 0
              && tall.Width == 300 && tall.Height == 600);
        Check("an empty box has no image rect", CropGeometry.Fit(0, 0, 0, 0).Width == 0);

        var start = new CropValue(0.2, 0.2, 0.6, 0.6);
        var grown = CropGeometry.Resize(start, CropCorner.BottomRight, 0.1, 0.1);
        Check("dragging the bottom-right corner grows the crop",
              Near(grown, 0.2, 0.2, 0.7, 0.7));
        var outward = CropGeometry.Resize(start, CropCorner.TopLeft, -5, -5);
        Check("a corner cannot leave the photo", Near(outward, 0, 0, 0.8, 0.8));
        var crossed = CropGeometry.Resize(start, CropCorner.TopLeft, 5, 0);
        Check("a corner cannot cross its opposite edge",
              Math.Abs(crossed.X - (0.8 - CropGeometry.MinimumSide)) < 1e-9
              && Math.Abs(crossed.Width - CropGeometry.MinimumSide) < 1e-9);
        var moved = CropGeometry.Move(start, 0.5, -0.5);
        Check("moving the crop keeps its size and stays inside",
              Near(moved, 0.4, 0, 0.6, 0.6));
        var clamped = CropGeometry.Clamp(new CropValue(-1, 2, 5, 0));
        Check("an arbitrary crop is brought inside",
              Near(clamped, 0, 1 - CropGeometry.MinimumSide, 1, CropGeometry.MinimumSide));
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
        Check("apply-orientation mirrors an unturned frame", Get(oriented, 0, 0).R == 200);

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

    /// <summary>
    /// The additive Crop/Straighten set (W4-8 Option A, approved 2026-11-15)
    /// rendered through the same orientation → crop → adjustments order the
    /// export uses, compared against the macOS references.
    ///
    /// Crop and mirror resample nothing, and the macOS harness proved its
    /// references are the exact cropped and mirrored fixture pixels, so those
    /// cases are parity gates: one differing level fails the run.
    ///
    /// A straighten resamples each host with a different filter (Core Image's
    /// affine versus this host's bilinear), and no numeric tolerance has been
    /// approved, so those cases measure and print MAE/PSNR without inventing a
    /// bound. They still gate the dimensions and the direction: a render with
    /// the angle negated must be measurably further from the reference than the
    /// one with the documented sign.
    /// </summary>
    private static void GeometryEvidence()
    {
        var repo = RepoRoot();
        var fixtures = Path.Combine(repo, "Tests/Corpus/Fixtures");
        var references = Path.Combine(repo, "Tests/Corpus/References");
        var codec = new WindowsImageCodec();
        var source = codec.DecodeAsync(Path.Combine(fixtures, "F13_geometry_grid.png"))
                          .GetAwaiter().GetResult();

        var cases = new (string Id, CropValue? Crop, OrientationValue Orientation,
                         int Width, int Height, bool Exact)[]
        {
            ("Q01_CROP_CENTER", new CropValue(0.25, 0.25, 0.5, 0.5),
             OrientationValue.Identity, 256, 192, true),
            ("Q02_CROP_EDGE", new CropValue(0, 0, 0.375, 0.5),
             OrientationValue.Identity, 192, 192, true),
            ("Q03_STRAIGHTEN_CW", null, OrientationValue.Identity.WithAngle(5),
             512, 384, false),
            ("Q04_STRAIGHTEN_CCW", null, OrientationValue.Identity.WithAngle(-7.5),
             512, 384, false),
            ("Q05_STRAIGHTEN_CROP", new CropValue(0.125, 0.125, 0.5, 0.5),
             OrientationValue.Identity.WithAngle(4), 256, 192, false),
            ("Q06_TURN_STRAIGHTEN_CROP", new CropValue(0.125, 0.25, 0.5, 0.5),
             OrientationValue.Identity.WithQuarterTurn(1).WithAngle(3), 192, 256, false),
            ("Q07_MIRROR_CROP", new CropValue(0.25, 0.125, 0.5, 0.75),
             OrientationValue.Identity.WithFlip(), 256, 288, true),
        };

        foreach (var (id, crop, orientation, width, height, exact) in cases)
        {
            var reference = codec.DecodeAsync(Path.Combine(references, id + ".png"))
                                 .GetAwaiter().GetResult();
            var rendered = ExportRunner.RenderDocument(source,
                new DocumentModel(new JsonObject())
                {
                    Crop = crop,
                    Orientation = orientation,
                });
            Check($"{id} renders the approved size",
                  rendered.Width == width && rendered.Height == height
                  && rendered.Width == reference.Width && rendered.Height == reference.Height);
            if (rendered.Width != reference.Width || rendered.Height != reference.Height)
            {
                continue;
            }

            var (mae, _, psnr, changed, _) = Compare(rendered, reference);
            Console.WriteLine($"  case {id}: mae {mae:0.###} psnr {psnr:0.##} dB " +
                              $"changed {changed:P1}");

            if (exact)
            {
                Check($"{id} matches the macOS reference exactly", mae == 0);
                continue;
            }

            var wrong = ExportRunner.RenderDocument(source,
                new DocumentModel(new JsonObject())
                {
                    Crop = crop,
                    Orientation = orientation with { Angle = -orientation.Angle },
                });
            var wrongMae = Compare(wrong, reference).Mae;
            Check($"{id} rotates in the documented direction", mae < wrongMae);
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

            // The turn is baked in first and the crop names the upright frame,
            // as macOS ImageProcessor.load does. The crop is deliberately not
            // square so a reversed order changes the frame, and the expected
            // pixels are built in the documented order.
            session.Document.Crop = new CropValue(0.25, 0.1, 0.5, 0.4);
            session.Document.Orientation = session.Document.Orientation.WithQuarterTurn(1);
            var cropped = Path.Combine(root, "depth-16-crop-turn.png");
            ExportRunner.ExportAsync(session, codec, cropped, "png", 1.0, 0)
                        .GetAwaiter().GetResult();
            var croppedBack = codec.Decode16Async(cropped).GetAwaiter().GetResult();
            var expected = p3.ApplyOrientation(session.Document.Orientation)
                             .Crop(session.Document.Crop!.Value);
            Check("a 16-bit export crops the upright frame after the turn",
                  croppedBack.Width == expected.Width
                  && croppedBack.Height == expected.Height
                  && croppedBack.Width == 256 && croppedBack.Height == 205);
            Check("a cropped 16-bit export keeps every sample",
                  croppedBack.Pixels.AsSpan().SequenceEqual(expected.Pixels));
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

        // Cancellation is cooperative between files: the one being written is
        // finished, so no half-written result is left behind.
        var cancelDir = Path.Combine(root, "batch-cancel");
        using var cancelToken = new CancellationTokenSource();
        var cancelling = new CancelAfterFirst(cancelToken);
        var cancelled = BatchExporter.ExportAsync(session.Document, codec,
            new BatchExportRequest(sources, cancelDir, "png", 1.0, 0, true),
            cancelling, cancelToken.Token).GetAwaiter().GetResult();
        Check("cancelling a batch stops after the file in flight",
              cancelled.Count == 1 && cancelling.Count == 1);
        Check("a cancelled batch keeps the file it finished",
              cancelled[0].Error is null && cancelled[0].Destination is not null
              && File.Exists(cancelled[0].Destination));
        Check("a cancelled batch starts no later file",
              !File.Exists(Path.Combine(cancelDir, "two-retouched.png"))
              && !File.Exists(Path.Combine(cancelDir, "three-retouched.png")));

        using var alreadyCancelled = new CancellationTokenSource();
        alreadyCancelled.Cancel();
        var preCancelledDir = Path.Combine(root, "batch-precancel");
        var preCancelled = BatchExporter.ExportAsync(session.Document, codec,
            new BatchExportRequest(sources, preCancelledDir, "png", 1.0, 0, true),
            null, alreadyCancelled.Token).GetAwaiter().GetResult();
        Check("a batch cancelled before it starts writes nothing",
              preCancelled.Count == 0
              && !Directory.EnumerateFiles(preCancelledDir).Any());

        // A person can press Cancel while a file is being rendered, so the
        // token is raised from inside the first file's pipeline rather than
        // between files. The file in flight is still finished and readable.
        var midDir = Path.Combine(root, "batch-midrender");
        using var midToken = new CancellationTokenSource();
        var midCodec = new CancelDuringFirstDecode(codec, midToken);
        var mid = BatchExporter.ExportAsync(session.Document, midCodec,
            new BatchExportRequest(sources, midDir, "png", 1.0, 0, true),
            null, midToken.Token).GetAwaiter().GetResult();
        Check("cancelling while a file is being rendered finishes that file",
              midCodec.Triggered && mid.Count == 1 && mid[0].Error is null
              && mid[0].Destination is not null && File.Exists(mid[0].Destination));
        Check("a mid-render cancel leaves a complete file",
              mid[0].Destination is not null
              && TryPngDepth(File.ReadAllBytes(mid[0].Destination), out var midDepth)
              && midDepth == 16);
        Check("a mid-render cancel starts no later file",
              !File.Exists(Path.Combine(midDir, "two-retouched.png")));
    }

    /// <summary>
    /// An encode that fails must not leave a partial photo at the destination:
    /// the write goes through a sibling temp file that is removed on failure,
    /// and an existing destination is only replaced by the final move.
    /// </summary>
    private static void AtomicExport(string root)
    {
        var codec = new WindowsImageCodec();
        var failing = new FailAfterWriting(codec);
        var source = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures/F01_portrait_srgb_8.png");
        var folder = Path.Combine(root, "atomic-export");
        Directory.CreateDirectory(folder);
        using var session = ProjectSession.Create(source);

        var missing = Path.Combine(folder, "never-written.png");
        var threw = false;
        try
        {
            ExportRunner.ExportSourceAsync(session.Document, failing, source, missing,
                                           "png", 1.0, 0).GetAwaiter().GetResult();
        }
        catch (IOException)
        {
            threw = true;
        }
        Check("a failed 16-bit export throws", threw);
        Check("a failed 16-bit export leaves no destination", !File.Exists(missing));
        Check("a failed 16-bit export leaves no temp file",
              Directory.GetFiles(folder, "*.tmp").Length == 0);

        var existing = Path.Combine(folder, "kept.jpg");
        var sentinel = new byte[] { 7, 7, 7, 7 };
        File.WriteAllBytes(existing, sentinel);
        threw = false;
        try
        {
            ExportRunner.ExportSourceAsync(session.Document, failing, source, existing,
                                           "jpeg", 0.9, 0).GetAwaiter().GetResult();
        }
        catch (IOException)
        {
            threw = true;
        }
        Check("a failed 8-bit export throws", threw);
        Check("a failed export keeps an existing destination byte-for-byte",
              File.ReadAllBytes(existing).SequenceEqual(sentinel));
        Check("a failed 8-bit export leaves no temp file",
              Directory.GetFiles(folder, "*.tmp").Length == 0);
    }

    /// <summary>
    /// Writes a few bytes to the path it is given — the runner's temp file —
    /// then fails, like a codec that hits a full disk or a broken container.
    /// </summary>
    private sealed class FailAfterWriting(IImageCodec inner) : IImageCodec
    {
        public Task<ImageSize> ReadSizeAsync(string path) => inner.ReadSizeAsync(path);

        public Task<int> ReadBitDepthAsync(string path) => inner.ReadBitDepthAsync(path);

        public Task<PixelBuffer> DecodeAsync(string path) => inner.DecodeAsync(path);

        public Task<PixelBuffer16> Decode16Async(string path) => inner.Decode16Async(path);

        public Task<ImageMetadata> ReadMetadataAsync(string path) =>
            inner.ReadMetadataAsync(path);

        public Task EncodeAsync(PixelBuffer image, string path, string format,
                                double quality, ImageMetadata? metadata = null,
                                bool stripPrivacyMetadata = true) =>
            FailAsync(path);

        public Task Encode16Async(PixelBuffer16 image, string path, string format,
                                  ImageMetadata? metadata = null,
                                  bool stripPrivacyMetadata = true) =>
            FailAsync(path);

        private static async Task FailAsync(string path)
        {
            await File.WriteAllBytesAsync(path, new byte[] { 0x42, 0x42, 0x42 });
            throw new IOException("the encoder failed");
        }
    }

    /// <summary>Cancels its batch from inside the first file's pipeline.</summary>
    private sealed class CancelDuringFirstDecode(IImageCodec inner,
                                                 CancellationTokenSource source)
        : IImageCodec
    {
        public bool Triggered { get; private set; }

        public Task<ImageSize> ReadSizeAsync(string path) => inner.ReadSizeAsync(path);

        public Task<int> ReadBitDepthAsync(string path) => inner.ReadBitDepthAsync(path);

        public Task<PixelBuffer> DecodeAsync(string path) => inner.DecodeAsync(path);

        public async Task<PixelBuffer16> Decode16Async(string path)
        {
            var buffer = await inner.Decode16Async(path);
            if (!Triggered)
            {
                Triggered = true;
                source.Cancel();
            }
            return buffer;
        }

        public Task<ImageMetadata> ReadMetadataAsync(string path) =>
            inner.ReadMetadataAsync(path);

        public Task EncodeAsync(PixelBuffer image, string path, string format,
                                double quality, ImageMetadata? metadata = null,
                                bool stripPrivacyMetadata = true) =>
            inner.EncodeAsync(image, path, format, quality, metadata,
                              stripPrivacyMetadata);

        public Task Encode16Async(PixelBuffer16 image, string path, string format,
                                  ImageMetadata? metadata = null,
                                  bool stripPrivacyMetadata = true) =>
            inner.Encode16Async(image, path, format, metadata, stripPrivacyMetadata);
    }

    /// <summary>Cancels its batch as soon as the first file has been reported.</summary>
    private sealed class CancelAfterFirst(CancellationTokenSource source)
        : IProgress<BatchExportItem>
    {
        public int Count { get; private set; }

        public void Report(BatchExportItem value)
        {
            Count++;
            if (Count == 1)
            {
                source.Cancel();
            }
        }
    }

    /// <summary>
    /// One individual export can be stopped after it starts. The token is
    /// raised from inside the codec, after bytes have reached the sibling
    /// temp, so the export has to unwind on its own: no temp, no new file and
    /// the previous destination byte-for-byte. A cancel that arrives before
    /// the encoder is entered must skip it, and a token cancelled before the
    /// call must skip the codec entirely.
    /// </summary>
    private static void ExportCancellation(string root)
    {
        var codec = new WindowsImageCodec();
        var source = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures/F01_portrait_srgb_8.png");
        var folder = Path.Combine(root, "export-cancel");
        Directory.CreateDirectory(folder);
        using var session = ProjectSession.Create(source);
        var sentinel = new byte[] { 0x11, 0x22, 0x33, 0x44 };

        var kept = Path.Combine(folder, "kept.jpg");
        File.WriteAllBytes(kept, sentinel);
        using var midEight = new CancellationTokenSource();
        var cancellingEight = new CancelDuringEncode(codec, midEight);
        var eightError = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
            session.Document, cancellingEight, source, kept, "jpeg", 0.9, 0,
            cancellationToken: midEight.Token));
        Check("a cancel inside an 8-bit write is an OperationCanceledException",
              eightError is OperationCanceledException cancelled
              && cancelled.CancellationToken == midEight.Token);
        Check("a cancelled 8-bit write still reached the encoder",
              cancellingEight.EncodeCalls == 1);
        Check("a cancelled 8-bit write leaves no temp sibling",
              Siblings(folder, "kept.jpg").Count == 0);
        Check("a cancelled 8-bit write keeps the existing destination",
              File.ReadAllBytes(kept).SequenceEqual(sentinel));

        var kept16 = Path.Combine(folder, "kept.png");
        File.WriteAllBytes(kept16, sentinel);
        using var midSixteen = new CancellationTokenSource();
        var cancellingSixteen = new CancelDuringEncode(codec, midSixteen);
        var sixteenError = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
            session.Document, cancellingSixteen, source, kept16, "png", 1.0, 0,
            cancellationToken: midSixteen.Token));
        Check("a cancel inside a 16-bit write is an OperationCanceledException",
              sixteenError is OperationCanceledException wide
              && wide.CancellationToken == midSixteen.Token);
        Check("a cancelled 16-bit write still reached the encoder",
              cancellingSixteen.Encode16Calls == 1);
        Check("a cancelled 16-bit write leaves no temp sibling",
              Siblings(folder, "kept.png").Count == 0);
        Check("a cancelled 16-bit write keeps the existing destination",
              File.ReadAllBytes(kept16).SequenceEqual(sentinel));

        using var preCancelled = new CancellationTokenSource();
        preCancelled.Cancel();
        var counting = new CountingCodec(codec);
        var never = Path.Combine(folder, "never.jpg");
        var preError = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
            session.Document, counting, source, never, "jpeg", 0.9, 0,
            cancellationToken: preCancelled.Token));
        Check("a token cancelled before the call is an OperationCanceledException",
              preError is OperationCanceledException);
        Check("a token cancelled before the call never reaches the codec",
              counting.Calls == 0);
        Check("a token cancelled before the call leaves no temp and no destination",
              !File.Exists(never) && Siblings(folder, "never.jpg").Count == 0);

        using var afterDecode = new CancellationTokenSource();
        var decodeCancelling = new CancelAfterDecode(codec, afterDecode);
        var unwritten = Path.Combine(folder, "after-decode.jpg");
        var decodeError = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
            session.Document, decodeCancelling, source, unwritten, "jpeg", 0.9, 0,
            cancellationToken: afterDecode.Token));
        Check("a cancel after decode is an OperationCanceledException",
              decodeError is OperationCanceledException);
        Check("a cancel after decode never invokes the encoder",
              decodeCancelling.EncodeCalls == 0);
        Check("a cancel after decode leaves no temp and no destination",
              !File.Exists(unwritten) && Siblings(folder, "after-decode.jpg").Count == 0);
    }

    /// <summary>
    /// An export onto a name that already exists replaces the file in one
    /// rename, so the new bytes appear whole and the previous file is gone
    /// without ever being half-written.
    /// </summary>
    private static void ExportDestination(string root)
    {
        var codec = new WindowsImageCodec();
        var source = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures/F01_portrait_srgb_8.png");
        var folder = Path.Combine(root, "export-destination");
        Directory.CreateDirectory(folder);
        using var session = ProjectSession.Create(source);
        var existing = Path.Combine(folder, "photo.jpg");
        var sentinel = Encoding.UTF8.GetBytes("the export that was here before");
        File.WriteAllBytes(existing, sentinel);

        var plan = ExportRunner.ExportSourceAsync(session.Document, codec, source, existing,
                                                  "jpeg", 0.9, 0).GetAwaiter().GetResult();
        var written = File.ReadAllBytes(existing);
        var decoded = codec.DecodeAsync(existing).GetAwaiter().GetResult();
        Check("a successful export replaces the existing destination",
              !written.SequenceEqual(sentinel) && written.Length > sentinel.Length);
        Check("the replacement is the photo the plan describes",
              decoded.Width == plan.Width && decoded.Height == plan.Height);
        Check("a successful export leaves no temp sibling",
              Siblings(folder, "photo.jpg").Count == 0);
        Check("a successful export leaves only the destination",
              Directory.GetFiles(folder).Length == 1);
    }

    /// <summary>
    /// A destination another program holds, and a destination that is a
    /// folder, both have to fail as a whole: the old bytes stay and no sibling
    /// temp is left behind. A read-only folder attribute is not used, because
    /// it does not stop file creation on Windows; the open handle is the real
    /// seam.
    /// </summary>
    private static void ExportRefusals(string root)
    {
        var codec = new WindowsImageCodec();
        var source = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures/F01_portrait_srgb_8.png");
        var folder = Path.Combine(root, "export-refused");
        Directory.CreateDirectory(folder);
        using var session = ProjectSession.Create(source);
        var sentinel = new byte[] { 0x77, 0x66, 0x55, 0x44 };

        var held = Path.Combine(folder, "held.jpg");
        File.WriteAllBytes(held, sentinel);
        using (var hold = new FileStream(held, FileMode.Open, FileAccess.ReadWrite,
                                         FileShare.Read))
        {
            var heldError = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
                session.Document, codec, source, held, "jpeg", 0.9, 0));
            Check("an export onto a held destination fails",
                  heldError is IOException or UnauthorizedAccessException);
        }
        // Read after the handle is released: the held stream shares reads but
        // not the write access a second open asks for.
        Check("a refused export keeps the held file byte-for-byte",
              File.ReadAllBytes(held).SequenceEqual(sentinel));
        Check("a refused export leaves no temp sibling",
              Siblings(folder, "held.jpg").Count == 0);

        var occupied = Path.Combine(folder, "occupied.jpg");
        Directory.CreateDirectory(occupied);
        var occupiedError = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
            session.Document, codec, source, occupied, "jpeg", 0.9, 0));
        Check("an export onto a folder fails",
              occupiedError is IOException or UnauthorizedAccessException);
        Check("an export onto a folder leaves the folder empty",
              Directory.Exists(occupied)
              && Directory.GetFileSystemEntries(occupied).Length == 0);
        Check("an export onto a folder leaves no temp sibling",
              Siblings(folder, "occupied.jpg").Count == 0);
    }

    /// <summary>
    /// The OS itself refusing the write, not a held handle: the current account
    /// is denied write on the destination folder through an ACL, so creating the
    /// temp file fails with UnauthorizedAccessException before any byte is
    /// staged. A probe write proves the deny is in force, so a skipped or
    /// ineffective ACE can never be mistaken for a passing refusal. The deny
    /// also blocks enumeration, so the folder is inspected after it is lifted.
    /// </summary>
    private static void ExportDeniedByAcl(string root)
    {
        var codec = new WindowsImageCodec();
        var source = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures/F01_portrait_srgb_8.png");
        var folder = Path.Combine(root, "export-acl-denied");
        Directory.CreateDirectory(folder);
        using var session = ProjectSession.Create(source);
        var account = string.IsNullOrEmpty(Environment.UserDomainName)
            ? Environment.UserName
            : $"{Environment.UserDomainName}\\{Environment.UserName}";
        var destination = Path.Combine(folder, "refused.jpg");
        var sentinel = new byte[] { 0x77, 0x66, 0x55, 0x44 };
        File.WriteAllBytes(destination, sentinel);

        var denied = RunIcacls($"{Quote(folder)} /deny \"{account}:(OI)(CI)W\"");
        Check("the deny ACE is installed on the destination folder", denied);
        if (!denied)
        {
            Directory.Delete(folder, recursive: true);
            return;
        }
        try
        {
            var probe = Path.Combine(folder, "probe.txt");
            var probeRefused = false;
            try
            {
                File.WriteAllText(probe, "x");
            }
            catch (UnauthorizedAccessException)
            {
                probeRefused = true;
            }
            Check("the deny ACE blocks this process from writing into the folder",
                  probeRefused);
            var error = AsyncErrorOf(() => ExportRunner.ExportSourceAsync(
                session.Document, codec, source, destination, "jpeg", 0.9, 0));
            Check("an export into a write-denied folder fails",
                  error is UnauthorizedAccessException or IOException);
        }
        finally
        {
            RunIcacls($"{Quote(folder)} /remove:d \"{account}\"");
        }
        Check("a write-denied export keeps the earlier destination byte-for-byte",
              File.ReadAllBytes(destination).SequenceEqual(sentinel));
        Check("a write-denied folder holds only the earlier destination and no temp",
              Directory.GetFileSystemEntries(folder).Length == 1);
        Directory.Delete(folder, recursive: true);
    }

    private static string Quote(string path) => $"\"{path}\"";

    private static bool RunIcacls(string arguments)
    {
        try
        {
            var info = new ProcessStartInfo("icacls", arguments)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var process = Process.Start(info);
            if (process is null)
            {
                return false;
            }
            if (!process.WaitForExit(30000))
            {
                process.Kill(entireProcessTree: true);
                return false;
            }
            return process.ExitCode == 0;
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or IOException)
        {
            return false;
        }
    }

    /// <summary>
    /// The launch sweep removes only the leftovers a crashed write of this
    /// destination could own: exact <c>.&lt;name&gt;.&lt;guid&gt;.tmp</c>
    /// siblings, and their one metadata tail, once they are old enough. A
    /// fresh temp, a similar name and a person's own file all survive, and a
    /// hidden leftover is still found because the sweep enumerates real files.
    /// </summary>
    private static void StaleSweep(string root)
    {
        var folder = Path.Combine(root, "stale-sweep");
        Directory.CreateDirectory(folder);
        var destinationName = "holiday.2026.final.png";
        var destination = Path.Combine(folder, destinationName);
        var now = new DateTime(2026, 11, 15, 12, 0, 0, DateTimeKind.Utc);
        var old = now.AddHours(-25);
        var fresh = now.AddHours(-1);
        var destinationBytes = new byte[] { 0x10, 0x20, 0x30 };
        File.WriteAllBytes(destination, destinationBytes);

        static string ExactAt(string directory, string name) =>
            Path.Combine(directory, $".{name}.{Guid.NewGuid():N}.tmp");
        static string MetadataAt(string directory, string name) =>
            Path.Combine(directory, $".{name}.{Guid.NewGuid():N}.tmp.metadata-{Guid.NewGuid():N}");

        var oldExact = ExactAt(folder, destinationName);
        var hiddenExact = ExactAt(folder, destinationName);
        var oldMetadata = MetadataAt(folder, destinationName);
        var freshExact = ExactAt(folder, destinationName);
        var freshMetadata = MetadataAt(folder, destinationName);
        var dotless = Path.Combine(folder, $"{destinationName}.{Guid.NewGuid():N}.tmp");
        var otherName = Path.Combine(folder, $".other-name.{Guid.NewGuid():N}.tmp");
        var missingDot = Path.Combine(folder,
            $".holiday.2026.final{Guid.NewGuid():N}.tmp");
        var userFile = Path.Combine(folder, "notes.txt");
        foreach (var path in new[] { oldExact, hiddenExact, oldMetadata, freshExact,
                                     freshMetadata, dotless, otherName, missingDot,
                                     userFile })
        {
            File.WriteAllText(path, "leftover");
        }
        File.SetAttributes(hiddenExact, FileAttributes.Hidden);
        foreach (var path in new[] { oldExact, hiddenExact, oldMetadata, userFile })
        {
            File.SetLastWriteTimeUtc(path, old);
        }
        foreach (var path in new[] { freshExact, freshMetadata, dotless, otherName,
                                     missingDot })
        {
            File.SetLastWriteTimeUtc(path, fresh);
        }
        File.SetLastWriteTimeUtc(destination, old);
        var destinationStamp = File.GetLastWriteTimeUtc(destination);

        Check("the sibling recogniser accepts the multi-dot name",
              TemporaryFiles.IsSiblingTemp(Path.GetFileName(oldExact), destinationName));
        Check("the hidden leftover is a real file the sweep can enumerate",
              (File.GetAttributes(hiddenExact) & FileAttributes.Hidden) != 0);

        var removed = TemporaryFiles.SweepStaleSiblings(destination, now,
                                                        TemporaryFiles.StaleAge);
        Check("the sweep removes exactly the stale exact siblings", removed == 3);
        Check("the sweep removes the old exact leftover", !File.Exists(oldExact));
        Check("the sweep removes a hidden old leftover", !File.Exists(hiddenExact));
        Check("the sweep removes the old metadata tail", !File.Exists(oldMetadata));
        Check("the sweep keeps a fresh exact sibling", File.Exists(freshExact));
        Check("the sweep keeps a fresh metadata tail", File.Exists(freshMetadata));
        Check("the sweep keeps a dotless name", File.Exists(dotless));
        Check("the sweep keeps the same basename under another name",
              File.Exists(otherName) && File.Exists(missingDot));
        Check("the sweep keeps a plain user file", File.Exists(userFile));
        Check("the sweep leaves the destination alone",
              File.Exists(destination)
              && File.ReadAllBytes(destination).SequenceEqual(destinationBytes)
              && File.GetLastWriteTimeUtc(destination) == destinationStamp);
        Check("a second sweep finds nothing to remove",
              TemporaryFiles.SweepStaleSiblings(destination, now,
                                                TemporaryFiles.StaleAge) == 0);
    }

    /// <summary>
    /// A project save that cannot publish its bytes must leave the previous
    /// project exactly as it was and the document exactly as it was: the path
    /// it was saved to and its dirty flag both stay, and a retry after the
    /// obstacle is gone writes the file with no temp left over.
    /// </summary>
    private static void ProjectSaveFailures(string root)
    {
        var folder = Path.Combine(root, "project-save");
        Directory.CreateDirectory(folder);
        var photo = Path.Combine(root, "project-save-photo.png");
        File.WriteAllBytes(photo, new byte[] { 1, 2, 3 });
        using var session = ProjectSession.Create(photo);

        var current = Path.Combine(folder, "kept.retouch");
        session.Save(current);
        var previous = File.ReadAllBytes(current);
        Check("a saved project is on disk and cleaned up",
              File.Exists(current) && Siblings(folder, "kept.retouch").Count == 0);

        var locked = Path.Combine(folder, "locked.retouch");
        var sentinel = new byte[] { 0x5A, 0x5A, 0x5A };
        File.WriteAllBytes(locked, sentinel);
        session.Document.SetAdjustment("exposure", 20);
        using (var hold = new FileStream(locked, FileMode.Open, FileAccess.ReadWrite,
                                         FileShare.Read))
        {
            var lockedError = ErrorOf(() => session.Save(locked));
            Check("saving over a held project fails",
                  lockedError is IOException or UnauthorizedAccessException);
            Check("a failed save leaves no temp sibling",
                  Siblings(folder, "locked.retouch").Count == 0);
        }
        // Read after the handle is released: the held stream shares reads but
        // not the write access a second open asks for.
        Check("a failed save leaves the held file byte-for-byte",
              File.ReadAllBytes(locked).SequenceEqual(sentinel));
        Check("a failed save leaves the earlier project untouched",
              File.ReadAllBytes(current).SequenceEqual(previous));
        Check("a failed save leaves the project path unchanged",
              session.ProjectPath == current);
        Check("a failed save leaves the document dirty", session.IsDirty());

        var asFolder = Path.Combine(folder, "looks-like-a-project.retouch");
        Directory.CreateDirectory(asFolder);
        var folderError = ErrorOf(() => session.Save(asFolder));
        Check("saving onto a directory fails",
              folderError is IOException or UnauthorizedAccessException);
        Check("saving onto a directory leaves the directory",
              Directory.Exists(asFolder)
              && Directory.GetFileSystemEntries(asFolder).Length == 0);
        Check("saving onto a directory leaves no temp sibling",
              Siblings(folder, "looks-like-a-project.retouch").Count == 0);

        session.Save(locked);
        Check("a retried save writes the project",
              File.Exists(locked) && new FileInfo(locked).Length > sentinel.Length);
        Check("a retried save leaves no temp sibling",
              Siblings(folder, "locked.retouch").Count == 0);
        Check("a retried save marks the document clean", !session.IsDirty());
        Check("a retried save records the new project path", session.ProjectPath == locked);
    }

    /// <summary>
    /// The recovery slot is the only mutable copy, so a write that cannot land
    /// must leave the previous copy whole and no temp behind. The same holds
    /// when the slot itself is an unresolved candidate: until the owner
    /// decides, an autosave must not replace the copy the launch offered.
    /// </summary>
    private static void RecoveryWriteFailures(string root)
    {
        var photo = Path.Combine(root, "recovery-write-photo.png");
        File.WriteAllBytes(photo, new byte[] { 4, 5, 6 });
        var at = new DateTimeOffset(2026, 11, 15, 9, 0, 0, TimeSpan.Zero);
        var context = Encoding.UTF8.GetBytes("""{"version":4}""");

        static byte[] ProjectFor(string imagePath, Action<JsonObject>? customize = null)
        {
            var document = new JsonObject
            {
                ["version"] = 4,
                ["imagePath"] = imagePath,
                ["adjustments"] = new JsonObject(),
                ["exportFormat"] = "jpeg",
                ["exportQuality"] = 0.92,
            };
            customize?.Invoke(document);
            return Encoding.UTF8.GetBytes(document.ToJsonString());
        }

        var first = RecoverySnapshot.Capture(ProjectFor(photo), context, photo, at);
        var second = RecoverySnapshot.Capture(
            ProjectFor(photo, document => document["adjustments"]!["exposure"] = 25),
            context, photo, at.AddMinutes(1));

        var store = new RecoveryStore(Path.Combine(root, "recovery-write"));
        Check("the working copy is written before the lock",
              store.WriteWorking(first, out _) && File.Exists(store.WorkingPath));
        var previous = File.ReadAllBytes(store.WorkingPath);
        bool written;
        using (new FileStream(store.WorkingPath, FileMode.Open, FileAccess.ReadWrite,
                              FileShare.None))
        {
            written = store.WriteWorking(second, out _);
        }
        Check("a working slot another program holds is not replaced", !written);
        Check("a failed working write keeps the previous bytes",
              File.ReadAllBytes(store.WorkingPath).SequenceEqual(previous));
        Check("a failed working write leaves no temp sibling",
              Siblings(store.Directory, RecoveryStore.WorkingFileName).Count == 0);

        var stuckStore = new RecoveryStore(Path.Combine(root, "recovery-stuck"));
        stuckStore.WriteWorking(first, out _);
        stuckStore.InjectedFailures.Add(RecoveryStore.Failure.Migrate);
        var offered = stuckStore.PrepareForLaunch();
        Check("a slot that cannot be lifted is offered as a candidate",
              offered.Count == 1
              && string.Equals(offered[0].Path, stuckStore.WorkingPath,
                               StringComparison.OrdinalIgnoreCase));
        var stuckBytes = File.ReadAllBytes(stuckStore.WorkingPath);
        var overwritten = stuckStore.WriteWorking(second, out _);
        Check("an unresolved slot is not overwritten by an autosave", !overwritten);
        Check("an unresolved slot keeps the bytes the launch offered",
              File.ReadAllBytes(stuckStore.WorkingPath).SequenceEqual(stuckBytes));
        Check("the refused autosave leaves no temp sibling",
              Siblings(stuckStore.Directory, RecoveryStore.WorkingFileName).Count == 0);
        stuckStore.InjectedFailures.Add(RecoveryStore.Failure.WorkingWrite);
        var restored = stuckStore.Restore(offered[0]);
        stuckStore.InjectedFailures.Clear();
        Check("a restore that cannot write reports failure", !restored);
        Check("a failed restore leaves the slot locked",
              !stuckStore.WriteWorking(second, out _)
              && File.ReadAllBytes(stuckStore.WorkingPath).SequenceEqual(stuckBytes));
        Check("discarding the copy frees the slot",
              stuckStore.Discard(offered[0]) && !File.Exists(stuckStore.WorkingPath));
        stuckStore.InjectedFailures.Clear();
        Check("after the slot is resolved an autosave writes again",
              stuckStore.WriteWorking(second, out _) && File.Exists(stuckStore.WorkingPath));
        Check("the copy that landed is the one written after the decision",
              stuckStore.ReadWorking()?.Document().Adjustment("exposure") == 25);
    }

    /// <summary>
    /// A single export and a batch are two writes of the same document, so
    /// neither may start while the other runs; the refusal has to arrive
    /// before either destination is touched. The guard lives in the window's
    /// view model, whose WPF types want an STA thread. That thread also gets a
    /// dispatcher context, so the checks run as work posted into a pumping
    /// loop; awaiting them from a bare STA thread would wait for a queue
    /// nothing drains.
    /// </summary>
    private static void ExportExclusion(string root)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
            async void Run()
            {
                try
                {
                    await ExportExclusionOnSta(root);
                }
                catch (Exception error)
                {
                    failure = error;
                }
                finally
                {
                    dispatcher.InvokeShutdown();
                }
            }
            dispatcher.InvokeAsync(Run);
            System.Windows.Threading.Dispatcher.Run();
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(TimeSpan.FromMinutes(5)))
        {
            throw new TimeoutException(
                "the export exclusion checks did not finish within five minutes");
        }
        if (failure is not null)
        {
            throw new InvalidOperationException(
                "the export exclusion checks failed", failure);
        }
    }

    private static async Task ExportExclusionOnSta(string root)
    {
        var source = Path.Combine(RepoRoot(), "Tests/Corpus/Fixtures/F01_portrait_srgb_8.png");
        var folder = Path.Combine(root, "export-exclusion");
        var batchFolder = Path.Combine(folder, "batch-out");
        var otherBatchFolder = Path.Combine(folder, "other-batch-out");
        Directory.CreateDirectory(folder);
        var singleTarget = Path.Combine(folder, "single.jpg");
        var otherTarget = Path.Combine(folder, "other.jpg");

        // The window's autosave folder must not be this machine's real one.
        var previousRecovery = Environment.GetEnvironmentVariable("RETOUCHSTUDIO_RECOVERY");
        Environment.SetEnvironmentVariable("RETOUCHSTUDIO_RECOVERY",
                                           Path.Combine(root, "export-exclusion-recovery"));
        try
        {
            var viewModel = new EditorViewModel();
            await viewModel.OpenImageAsync(source);
            Check("the editor holds the photo before the exclusion checks",
                  viewModel.HasDocument);

            var batch = viewModel.BatchExportAsync(new[] { source }, batchFolder);
            Check("a running batch is marked as running", viewModel.IsBatchRunning);
            var refusedSingle = AsyncErrorOf(() => viewModel.ExportAsync(singleTarget));
            Check("a single export is refused while a batch runs",
                  refusedSingle is InvalidOperationException);
            Check("a refused single export writes nothing", !File.Exists(singleTarget));
            Check("a refused single export does not claim the single slot",
                  !viewModel.IsExportRunning);
            await batch;
            Check("the batch that held the lock still exported",
                  Directory.Exists(batchFolder)
                  && Directory.GetFiles(batchFolder, "*.jpg").Length == 1);

            var single = viewModel.ExportAsync(otherTarget);
            Check("a running single export is marked as running",
                  viewModel.IsExportRunning);
            var refusedBatch = AsyncErrorOf(() => viewModel.BatchExportAsync(
                new[] { source }, otherBatchFolder));
            Check("a batch is refused while a single export runs",
                  refusedBatch is InvalidOperationException);
            Check("a refused batch creates no destination folder",
                  !Directory.Exists(otherBatchFolder));
            Check("a refused batch does not claim the batch slot",
                  !viewModel.IsBatchRunning);
            await single;
            Check("the single export that held the lock still wrote its file",
                  File.Exists(otherTarget));
        }
        finally
        {
            Environment.SetEnvironmentVariable("RETOUCHSTUDIO_RECOVERY", previousRecovery);
        }
    }

    /// <summary>
    /// Writes a few bytes to the path it is given — the runner's temp file —
    /// then raises its own token, as a person pressing Cancel mid-encode does.
    /// It does not throw: the cancellation must come from the runner's check
    /// between the encode and the rename, or a passing test would prove
    /// nothing about that check.
    /// </summary>
    private sealed class CancelDuringEncode(IImageCodec inner, CancellationTokenSource source)
        : IImageCodec
    {
        public int EncodeCalls { get; private set; }
        public int Encode16Calls { get; private set; }

        public Task<ImageSize> ReadSizeAsync(string path) => inner.ReadSizeAsync(path);

        public Task<int> ReadBitDepthAsync(string path) => inner.ReadBitDepthAsync(path);

        public Task<PixelBuffer> DecodeAsync(string path) => inner.DecodeAsync(path);

        public Task<PixelBuffer16> Decode16Async(string path) => inner.Decode16Async(path);

        public Task<ImageMetadata> ReadMetadataAsync(string path) =>
            inner.ReadMetadataAsync(path);

        public async Task EncodeAsync(PixelBuffer image, string path, string format,
                                      double quality, ImageMetadata? metadata = null,
                                      bool stripPrivacyMetadata = true)
        {
            EncodeCalls++;
            await File.WriteAllBytesAsync(path, new byte[] { 0x51, 0x52, 0x53 });
            source.Cancel();
        }

        public async Task Encode16Async(PixelBuffer16 image, string path, string format,
                                        ImageMetadata? metadata = null,
                                        bool stripPrivacyMetadata = true)
        {
            Encode16Calls++;
            await File.WriteAllBytesAsync(path, new byte[] { 0x54, 0x55, 0x56, 0x57 });
            source.Cancel();
        }
    }

    /// <summary>Counts every codec call; a pre-cancelled export must make none.</summary>
    private sealed class CountingCodec(IImageCodec inner) : IImageCodec
    {
        public int Calls { get; private set; }

        public Task<ImageSize> ReadSizeAsync(string path)
        {
            Calls++;
            return inner.ReadSizeAsync(path);
        }

        public Task<int> ReadBitDepthAsync(string path)
        {
            Calls++;
            return inner.ReadBitDepthAsync(path);
        }

        public Task<PixelBuffer> DecodeAsync(string path)
        {
            Calls++;
            return inner.DecodeAsync(path);
        }

        public Task<PixelBuffer16> Decode16Async(string path)
        {
            Calls++;
            return inner.Decode16Async(path);
        }

        public Task<ImageMetadata> ReadMetadataAsync(string path)
        {
            Calls++;
            return inner.ReadMetadataAsync(path);
        }

        public Task EncodeAsync(PixelBuffer image, string path, string format,
                                double quality, ImageMetadata? metadata = null,
                                bool stripPrivacyMetadata = true)
        {
            Calls++;
            return inner.EncodeAsync(image, path, format, quality, metadata,
                                     stripPrivacyMetadata);
        }

        public Task Encode16Async(PixelBuffer16 image, string path, string format,
                                  ImageMetadata? metadata = null,
                                  bool stripPrivacyMetadata = true)
        {
            Calls++;
            return inner.Encode16Async(image, path, format, metadata,
                                       stripPrivacyMetadata);
        }
    }

    /// <summary>
    /// Raises its token as soon as the decode returns, so the cancel arrives
    /// after the pixels are in hand and before the encoder is entered.
    /// </summary>
    private sealed class CancelAfterDecode(IImageCodec inner, CancellationTokenSource source)
        : IImageCodec
    {
        public int EncodeCalls { get; private set; }

        public Task<ImageSize> ReadSizeAsync(string path) => inner.ReadSizeAsync(path);

        public Task<int> ReadBitDepthAsync(string path) => inner.ReadBitDepthAsync(path);

        public async Task<PixelBuffer> DecodeAsync(string path)
        {
            var buffer = await inner.DecodeAsync(path);
            source.Cancel();
            return buffer;
        }

        public Task<PixelBuffer16> Decode16Async(string path) => inner.Decode16Async(path);

        public Task<ImageMetadata> ReadMetadataAsync(string path) =>
            inner.ReadMetadataAsync(path);

        public Task EncodeAsync(PixelBuffer image, string path, string format,
                                double quality, ImageMetadata? metadata = null,
                                bool stripPrivacyMetadata = true)
        {
            EncodeCalls++;
            return inner.EncodeAsync(image, path, format, quality, metadata,
                                     stripPrivacyMetadata);
        }

        public Task Encode16Async(PixelBuffer16 image, string path, string format,
                                  ImageMetadata? metadata = null,
                                  bool stripPrivacyMetadata = true)
        {
            EncodeCalls++;
            return inner.Encode16Async(image, path, format, metadata,
                                       stripPrivacyMetadata);
        }
    }

    /// <summary>
    /// The leftover siblings of one destination name: the dot-prefixed files a
    /// finished write renames away, so finding one means a write did not land.
    /// </summary>
    private static List<string> Siblings(string folder, string destinationName) =>
        Directory.EnumerateFiles(folder)
                 .Where(path => TemporaryFiles.IsSiblingTemp(Path.GetFileName(path),
                                                             destinationName))
                 .ToList();

    private static Exception? ErrorOf(Action action)
    {
        try
        {
            action();
            return null;
        }
        catch (Exception error)
        {
            return error;
        }
    }

    private static Exception? AsyncErrorOf(Func<Task> action)
    {
        try
        {
            action().GetAwaiter().GetResult();
            return null;
        }
        catch (Exception error)
        {
            return error;
        }
    }

    private static string Sha256(string path) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(path)));

    /// <summary>Largest per-channel difference between two 8-bit buffers.</summary>
    private static bool Near(CropValue value, double x, double y, double width, double height) =>
        Math.Abs(value.X - x) < 1e-9 && Math.Abs(value.Y - y) < 1e-9
        && Math.Abs(value.Width - width) < 1e-9
        && Math.Abs(value.Height - height) < 1e-9;

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

    /// <summary>Reads chosen properties straight from the platform decoder.</summary>
    private static async Task<BitmapPropertySet> DecodeProperties(string path, string[] keys)
    {
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        return await decoder.BitmapProperties.GetPropertiesAsync(keys);
    }

    /// <summary>Prints what the platform decoder actually returned for a key.</summary>
    private static void Describe(BitmapPropertySet set, string key)
    {
        if (!set.TryGetValue(key, out var typed))
        {
            Console.WriteLine($"  decoded {key}: absent");
            return;
        }
        var value = typed.Value;
        var text = value switch
        {
            double[] parts => string.Join(", ", parts),
            null => "null",
            _ => value.ToString(),
        };
        Console.WriteLine($"  decoded {key}: {value?.GetType().FullName} = {text}");
    }

    /// <summary>
    /// Every pixel on this host is converted to sRGB at decode, so an export
    /// that declares nothing is read back as sRGB by convention rather than by
    /// contract. The shipping writer now embeds a generated sRGB profile in
    /// JPEG and PNG; each container is read back and the profile bytes must be
    /// identical in both. TIFF stays untagged until a TIFF writer exists and is
    /// printed, not asserted, so the gap is visible in the log.
    /// </summary>
    private static void Colour(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(16, 12);
        for (var y = 0; y < 12; y++)
        {
            for (var x = 0; x < 16; x++)
            {
                Put(image, x, y, r: (byte)(x * 15), g: (byte)(y * 20), b: (byte)(255 - x * 12));
            }
        }

        var source = Path.Combine(root, "colour-source.jpg");
        codec.EncodeAsync(image, source, "jpeg", 0.95).GetAwaiter().GetResult();
        Console.WriteLine($"  colour source JPEG: {DescribeColourProfile(source)}");

        using var session = ProjectSession.Create(source);
        var jpeg = Path.Combine(root, "colour-export.jpg");
        ExportRunner.ExportAsync(session, codec, jpeg, "jpeg", 0.9, 0)
                     .GetAwaiter().GetResult();
        var png = Path.Combine(root, "colour-export.png");
        ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0)
                     .GetAwaiter().GetResult();
        var tiff = Path.Combine(root, "colour-export.tiff");
        ExportRunner.ExportAsync(session, codec, tiff, "tiff", 1.0, 0)
                     .GetAwaiter().GetResult();
        var stripped = Path.Combine(root, "colour-export-stripped.jpg");
        ExportRunner.ExportAsync(session, codec, stripped, "jpeg", 0.9, 0)
                     .GetAwaiter().GetResult();

        var jpegProfile = ColourProfileBytes(jpeg);
        Check("an exported JPEG declares an RGB display profile",
              jpegProfile is { Length: > 1024 }
              && Encoding.ASCII.GetString(jpegProfile, 16, 4) == "RGB "
              && Encoding.ASCII.GetString(jpegProfile, 12, 4) == "mntr");
        Check("the JPEG profile carries the generated description",
              jpegProfile is not null
              && IccDescription(jpegProfile) == SrgbProfile.Description);
        var pngProfile = ColourProfileBytes(png);
        Check("an exported PNG declares the same profile bytes",
              pngProfile is not null && jpegProfile is not null
              && pngProfile.SequenceEqual(jpegProfile));
        Check("stripping the source identity keeps the colour profile",
              ColourProfileBytes(stripped) is not null);
        Console.WriteLine($"  colour TIFF (documented gap): {DescribeColourProfile(tiff)}");
    }

    private static byte[]? ColourProfileBytes(string path)
    {
        var bytes = File.ReadAllBytes(path);
        return bytes.Length > 8 && bytes[0] == 0xFF && bytes[1] == 0xD8
            ? JpegColourProfile(bytes)
            : bytes.Length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50
                ? PngColourProfile(bytes)
                : TiffColourProfile(bytes);
    }

    private static string DescribeColourProfile(string path)
    {
        byte[]? profile;
        try
        {
            profile = ColourProfileBytes(path);
        }
        catch (Exception error)
        {
            return $"unreadable ({error.Message})";
        }
        if (profile is null)
        {
            return "no embedded profile (readers assume sRGB)";
        }
        if (profile.Length < 132)
        {
            return $"embedded profile too short ({profile.Length} bytes)";
        }
        var space = Encoding.ASCII.GetString(profile, 16, 4).TrimEnd('\0', ' ');
        var profileClass = Encoding.ASCII.GetString(profile, 12, 4).TrimEnd('\0', ' ');
        var description = IccDescription(profile) ?? "unnamed";
        return "embedded " + space + " " + profileClass + " profile, \"" +
               description + "\", " + profile.Length + " bytes";
    }

    private static byte[]? JpegColourProfile(byte[] bytes)
    {
        var segments = new SortedDictionary<byte, byte[]>();
        var at = 2;
        while (at + 4 <= bytes.Length && bytes[at] == 0xFF)
        {
            var marker = bytes[at + 1];
            if (marker == 0xDA || marker == 0xD9)
            {
                break;
            }
            if (marker is >= 0xD0 and <= 0xD8)
            {
                at += 2;
                continue;
            }
            var length = (bytes[at + 2] << 8) | bytes[at + 3];
            if (length < 2 || at + 2 + length > bytes.Length)
            {
                break;
            }
            if (marker == 0xE2 && length >= 16)
            {
                var payload = at + 4;
                // "ICC_PROFILE\0" then the segment number and the segment count.
                if (Encoding.ASCII.GetString(bytes, payload, 11) == "ICC_PROFILE"
                    && bytes[payload + 11] == 0)
                {
                    segments[bytes[payload + 12]] = bytes[(payload + 14)..(at + 2 + length)];
                }
            }
            at += 2 + length;
        }
        return segments.Count == 0 ? null : segments.Values.SelectMany(part => part).ToArray();
    }

    private static byte[]? PngColourProfile(byte[] bytes)
    {
        var at = 8;
        while (at + 12 <= bytes.Length)
        {
            var length = (bytes[at] << 24) | (bytes[at + 1] << 16)
                       | (bytes[at + 2] << 8) | bytes[at + 3];
            if (length < 0 || at + 12 + length > bytes.Length)
            {
                return null;
            }
            var type = Encoding.ASCII.GetString(bytes, at + 4, 4);
            if (type == "iCCP")
            {
                var data = new ReadOnlySpan<byte>(bytes, at + 8, length);
                var zero = data.IndexOf((byte)0);
                if (zero < 0 || zero + 2 > data.Length)
                {
                    return null;
                }
                // A profile name, a compression method byte, then the profile.
                using var compressed = new MemoryStream(data[(zero + 2)..].ToArray());
                using var zlib = new ZLibStream(compressed, CompressionMode.Decompress);
                using var plain = new MemoryStream();
                zlib.CopyTo(plain);
                return plain.ToArray();
            }
            if (type == "IEND")
            {
                break;
            }
            at += 12 + length;
        }
        return null;
    }

    private static byte[]? TiffColourProfile(byte[] bytes)
    {
        if (bytes.Length < 8)
        {
            return null;
        }
        var little = bytes[0] == 0x49;
        var offset = (int)ColourTiffU32(bytes, 4, little);
        if (offset < 8 || offset + 2 > bytes.Length)
        {
            return null;
        }
        var count = ColourTiffU16(bytes, offset, little);
        for (var i = 0; i < count; i++)
        {
            var entry = offset + 2 + i * 12;
            if (entry + 12 > bytes.Length)
            {
                return null;
            }
            if (ColourTiffU16(bytes, entry, little) != 34675)
            {
                continue;
            }
            var length = (int)ColourTiffU32(bytes, entry + 4, little);
            if (length < 0 || length > bytes.Length)
            {
                return null;
            }
            var start = length <= 4 ? entry + 8 : (int)ColourTiffU32(bytes, entry + 8, little);
            if (start + length > bytes.Length)
            {
                return null;
            }
            return bytes[start..(start + length)];
        }
        return null;
    }

    private static ushort ColourTiffU16(byte[] bytes, int at, bool little) =>
        little
            ? (ushort)(bytes[at] | (bytes[at + 1] << 8))
            : (ushort)((bytes[at] << 8) | bytes[at + 1]);

    private static uint ColourTiffU32(byte[] bytes, int at, bool little) =>
        little
            ? (uint)bytes[at] | ((uint)bytes[at + 1] << 8)
              | ((uint)bytes[at + 2] << 16) | ((uint)bytes[at + 3] << 24)
            : ((uint)bytes[at] << 24) | ((uint)bytes[at + 1] << 16)
              | ((uint)bytes[at + 2] << 8) | bytes[at + 3];

    /// <summary>
    /// The human description of an ICC profile, from a v2 `desc` tag or a v4
    /// `mluc` tag. A profile without a readable description still counts as
    /// embedded; the header fields carry the colour space either way.
    /// </summary>
    private static string? IccDescription(byte[] profile)
    {
        var count = (int)ColourTiffU32(profile, 128, little: false);
        if (count < 0 || count > 64 || 132 + count * 12 > profile.Length)
        {
            return null;
        }
        for (var i = 0; i < count; i++)
        {
            var entry = 132 + i * 12;
            var signature = Encoding.ASCII.GetString(profile, entry, 4);
            var offset = (int)ColourTiffU32(profile, entry + 4, little: false);
            if (offset < 0 || offset + 12 > profile.Length)
            {
                continue;
            }
            if (signature == "desc")
            {
                var length = (int)ColourTiffU32(profile, offset + 8, little: false);
                if (length > 0 && length <= 256 && offset + 12 + length <= profile.Length)
                {
                    return Encoding.ASCII.GetString(profile, offset + 12, length).TrimEnd('\0');
                }
            }
            if (signature == "mluc")
            {
                var records = (int)ColourTiffU32(profile, offset + 8, little: false);
                if (records < 1 || records > 8 || offset + 28 > profile.Length)
                {
                    continue;
                }
                var length = (int)ColourTiffU32(profile, offset + 20, little: false);
                var start = offset + (int)ColourTiffU32(profile, offset + 24, little: false);
                if (length > 0 && length <= 512 && start + length <= profile.Length)
                {
                    return Encoding.BigEndianUnicode.GetString(profile, start, length).TrimEnd('\0');
                }
            }
        }
        return null;
    }

    /// <summary>
    /// Metadata the WinRT writer cannot express: the source EXIF block and XMP
    /// packet are carried at the container level, the orientation is made
    /// upright, the frame dimensions are replaced and the thumbnail is unlinked.
    /// The decoder is asked to read the carried model back, so the block is
    /// proved to be real EXIF, not only bytes the host wrote and re-read.
    /// </summary>
    private static void Carry(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(8, 6);
        for (var y = 0; y < 6; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                Put(image, x, y, r: 40, g: 60, b: 80);
            }
        }

        var exif = BuildExif(orientation: 6, width: 8, height: 6);
        var xmp = Encoding.UTF8.GetBytes(
            "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF>"
            + "<rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:tiff=\"http://ns.adobe.com/tiff/1.0/\" "
            + "dc:title=\"Carry test\" tiff:Orientation=\"6\"/>"
            + "</rdf:RDF></x:xmpmeta>");

        var source = Path.Combine(root, "carry-source.jpg");
        codec.EncodeAsync(image, source, "jpeg", 0.95).GetAwaiter().GetResult();
        MetadataCarry.WriteJpeg(source, exif, xmp);

        // An editor's Photoshop block: the IPTC resource this writer must carry
        // and a resolution resource it must not, since the exported frame has a
        // different size.
        var expectedIptc = BuildResource(0x0404, IptcTitle("IPTC carry"));
        InsertApp13(source, Join(
            BuildResource(0x03ED, new byte[] { 0, 72, 0, 0, 0, 1, 0, 1, 0, 72, 0, 0, 0, 1, 0, 1 }),
            expectedIptc));

        var sourceRead = codec.ReadMetadataAsync(source).GetAwaiter().GetResult();
        Check("the Windows decoder reads a carried EXIF block",
              Text(sourceRead, "System.Photo.CameraModel") == "RS-Carry");
        Check("the carried XMP packet is readable",
              sourceRead.Xmp is { } sourceXmp
              && Encoding.UTF8.GetString(sourceXmp).Contains("Carry test"));
        Check("the IPTC resource is read from a Photoshop APP13 block",
              sourceRead.Iptc is not null && sourceRead.Iptc.SequenceEqual(expectedIptc));

        using var session = ProjectSession.Create(source);
        var kept = Path.Combine(root, "carry-kept.jpg");
        ExportRunner.ExportAsync(session, codec, kept, "jpeg", 0.9, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var keptExif = MetadataCarry.ReadExif(kept);
        var keptSize = codec.ReadSizeAsync(kept).GetAwaiter().GetResult();
        Check("a kept export carries the source EXIF block", keptExif is not null);
        Check("the carried EXIF is upright", TiffNumber(keptExif, 0x0112) == 1);
        Check("the carried EXIF names the exported frame",
              TiffNumber(keptExif, 0xA002) == keptSize.Width
              && TiffNumber(keptExif, 0xA003) == keptSize.Height);
        Check("the carried EXIF keeps the model",
              TiffText(keptExif, 0x0110) == "RS-Carry");
        Check("the carried EXIF keeps the capture date",
              TiffText(keptExif, 0x0132) == "2024:05:17 10:30:00");
        var keptRead = codec.ReadMetadataAsync(kept).GetAwaiter().GetResult();
        Check("the Windows decoder reads the carried model in the export",
              Text(keptRead, "System.Photo.CameraModel") == "RS-Carry");
        var keptXmp = MetadataCarry.ReadXmp(kept);
        Check("the carried XMP keeps the title",
              keptXmp is not null
              && Encoding.UTF8.GetString(keptXmp).Contains("Carry test"));
        Check("the carried XMP is upright",
              keptXmp is not null
              && Encoding.UTF8.GetString(keptXmp).Contains("tiff:Orientation=\"1\""));
        var keptIptc = MetadataCarry.ReadIptc(kept);
        Check("a kept JPEG export carries the source IPTC resource",
              keptIptc is not null && keptIptc.SequenceEqual(expectedIptc));

        var stripped = Path.Combine(root, "carry-stripped.jpg");
        ExportRunner.ExportAsync(session, codec, stripped, "jpeg", 0.9, 0)
                             .GetAwaiter().GetResult();
        Check("stripping leaves no carried EXIF", MetadataCarry.ReadExif(stripped) is null);
        Check("stripping leaves no XMP", MetadataCarry.ReadXmp(stripped) is null);
        Check("stripping leaves no IPTC", MetadataCarry.ReadIptc(stripped) is null);

        var png = Path.Combine(root, "carry-kept.png");
        ExportRunner.ExportAsync(session, codec, png, "png", 1.0, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var pngExif = MetadataCarry.ReadExif(png);
        Check("a kept 16-bit PNG carries the EXIF block", pngExif is not null);
        Check("the PNG EXIF is upright", TiffNumber(pngExif, 0x0112) == 1);
        Check("the PNG carries the XMP packet", MetadataCarry.ReadXmp(png) is not null);
        Check("a PNG export has no IPTC container", MetadataCarry.ReadIptc(png) is null);

        var badIptc = Path.Combine(root, "carry-bad-iptc.jpg");
        codec.EncodeAsync(image, badIptc, "jpeg", 0.95).GetAwaiter().GetResult();
        InsertApp13(badIptc, new byte[]
        {
            (byte)'8', (byte)'B', (byte)'I', (byte)'M', 0x04, 0x04, 0, 0,
            0x7F, 0xFF, 0xFF, 0xFF,
        });
        Check("a malformed IPTC block is skipped", MetadataCarry.ReadIptc(badIptc) is null);

        var broken = Path.Combine(root, "carry-broken.jpg");
        codec.EncodeAsync(image, broken, "jpeg", 0.95).GetAwaiter().GetResult();
        MetadataCarry.WriteJpeg(
            broken,
            new byte[] { (byte)'I', (byte)'I', 42, 0, 0xFF, 0xFF, 0xFF, 0x7F },
            null);
        using var brokenSession = ProjectSession.Create(broken);
        var brokenOut = Path.Combine(root, "carry-broken-out.jpg");
        ExportRunner.ExportAsync(brokenSession, codec, brokenOut, "jpeg", 0.9, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var brokenSize = codec.ReadSizeAsync(brokenOut).GetAwaiter().GetResult();
        Check("an invalid EXIF block is skipped without failing the export",
              brokenSize.Width == 8 && brokenSize.Height == 6);
    }

    /// <summary>
    /// The carried metadata describes the pixels the writer produced, not the
    /// photo that was opened. A crop, a quarter turn and a long-edge resize each
    /// change the frame through the shipping export path; every transformed
    /// export must stay upright, name the exported frame and leave no camera
    /// thumbnail.
    /// </summary>
    private static void CarryTransforms(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(40, 30);
        for (var y = 0; y < 30; y++)
        {
            for (var x = 0; x < 40; x++)
            {
                Put(image, x, y, r: (byte)(x * 6), g: (byte)(y * 8), b: 120);
            }
        }

        var source = Path.Combine(root, "transform-source.jpg");
        codec.EncodeAsync(image, source, "jpeg", 0.95).GetAwaiter().GetResult();
        MetadataCarry.WriteJpeg(
            source,
            BuildExif(orientation: 6, width: 40, height: 30),
            Encoding.UTF8.GetBytes(
                "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF>"
                + "<rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
                + "xmlns:tiff=\"http://ns.adobe.com/tiff/1.0/\" "
                + "dc:title=\"Transform test\" tiff:Orientation=\"6\"/>"
                + "</rdf:RDF></x:xmpmeta>"));

        // The source decodes upright as 30x40, so a half-size crop is exactly
        // 15x20 and no rounding can hide behind it.
        using (var session = ProjectSession.Create(source))
        {
            session.Document.Crop = new CropValue(0.5, 0.5, 0.5, 0.5);
            var path = Path.Combine(root, "transform-cropped.jpg");
            ExportRunner.ExportAsync(session, codec, path, "jpeg", 0.9, 0,
                                     stripPrivacyMetadata: false).GetAwaiter().GetResult();
            var size = codec.ReadSizeAsync(path).GetAwaiter().GetResult();
            var exif = MetadataCarry.ReadExif(path);
            var xmp = MetadataCarry.ReadXmp(path);
            Check("a crop exports the cropped frame", size.Width == 15 && size.Height == 20);
            Check("a cropped export names the cropped frame in EXIF",
                  TiffNumber(exif, 0xA002) == size.Width
                  && TiffNumber(exif, 0xA003) == size.Height);
            Check("a cropped export is upright", TiffNumber(exif, 0x0112) == 1);
            Check("a cropped export keeps the XMP title",
                  xmp is not null && Encoding.UTF8.GetString(xmp).Contains("Transform test"));
            Check("a cropped export leaves no camera thumbnail",
                  (TiffNumber(exif, 0x0201) ?? 0) == 0);
        }

        using (var session = ProjectSession.Create(source))
        {
            session.Document.Orientation = session.Document.Orientation.WithQuarterTurn(1);
            var path = Path.Combine(root, "transform-turned.jpg");
            ExportRunner.ExportAsync(session, codec, path, "jpeg", 0.9, 0,
                                     stripPrivacyMetadata: false).GetAwaiter().GetResult();
            var size = codec.ReadSizeAsync(path).GetAwaiter().GetResult();
            var exif = MetadataCarry.ReadExif(path);
            Check("a quarter turn exports the turned frame",
                  size.Width == 40 && size.Height == 30);
            Check("a turned export names the turned frame in EXIF",
                  TiffNumber(exif, 0xA002) == size.Width
                  && TiffNumber(exif, 0xA003) == size.Height);
            Check("a turned export is upright", TiffNumber(exif, 0x0112) == 1);
        }

        using (var session = ProjectSession.Create(source))
        {
            var path = Path.Combine(root, "transform-resized.jpg");
            ExportRunner.ExportAsync(session, codec, path, "jpeg", 0.9, 20,
                                     stripPrivacyMetadata: false).GetAwaiter().GetResult();
            var size = codec.ReadSizeAsync(path).GetAwaiter().GetResult();
            var exif = MetadataCarry.ReadExif(path);
            Check("a long-edge resize exports the resized frame",
                  size.Width == 15 && size.Height == 20);
            Check("a resized export names the resized frame in EXIF",
                  TiffNumber(exif, 0xA002) == size.Width
                  && TiffNumber(exif, 0xA003) == size.Height);
            Check("a resized export is upright", TiffNumber(exif, 0x0112) == 1);
        }
    }

    /// <summary>
    /// A source whose EXIF cannot be spliced — a TIFF photo, or a broken
    /// segment — still knows how it was taken. The composer rebuilds the tags
    /// the WinRT writer drops from the decoded properties, and the same decoder
    /// that produced the properties reads the composed block back.
    /// </summary>
    private static void Compose(string root)
    {
        var codec = new WindowsImageCodec();
        var image = new PixelBuffer(8, 6);
        for (var y = 0; y < 6; y++)
        {
            for (var x = 0; x < 8; x++)
            {
                Put(image, x, y, r: 40, g: 60, b: 80);
            }
        }

        var properties = new Dictionary<string, object>
        {
            ["System.Photo.CameraManufacturer"] = "Retouch",
            ["System.Photo.CameraModel"] = "RS-Compose",
            ["System.Photo.DateTaken"] = new DateTime(2024, 5, 17, 10, 30, 0),
            ["System.Photo.ExposureTime"] = 0.008,
            ["System.Photo.FNumber"] = 2.8,
            ["System.Photo.IsoSpeed"] = (ushort)400,
            ["System.Photo.Flash"] = (ushort)16,
            ["System.Photo.WhiteBalance"] = (ushort)1,
            ["System.Photo.FocalLength"] = 50.0,
            ["System.Photo.LensModel"] = "RF 50mm F1.8",
            ["System.GPS.Latitude"] = new[] { 35.0, 41.0, 12.0 },
            ["System.GPS.LatitudeRef"] = "N",
            ["System.GPS.Longitude"] = new[] { 51.0, 25.0, 3.0 },
            ["System.GPS.LongitudeRef"] = "E",
            ["System.GPS.Altitude"] = 1200.0,
        };
        var composed = ExifComposer.Build(properties, 300, 300);
        Check("the composer builds an EXIF block", composed is not null);
        Check("the composed block names the camera", TiffText(composed, 0x0110) == "RS-Compose");
        Check("the composed block is upright", TiffNumber(composed, 0x0112) == 1);
        Check("a source with nothing to describe composes no block",
              ExifComposer.Build(new Dictionary<string, object>(), 72, 72) is null);

        Check("the composed block records the capture time",
              TiffText(composed, ExifComposer.TagDateTimeOriginal) == "2024:05:17 10:30:00");
        Check("the composed block records the GPS position",
              composed is not null
              && FindTiffEntry(composed, ExifComposer.TagGpsLatitude, out var gpsType,
                               out var gpsCount, out _, out _)
              && gpsType == 5 && gpsCount == 3);

        var spliced = Path.Combine(root, "compose-spliced.jpg");
        codec.EncodeAsync(image, spliced, "jpeg", 0.95).GetAwaiter().GetResult();
        MetadataCarry.WriteJpeg(spliced, composed, null);
        var splicedBlock = MetadataCarry.ReadExif(spliced);
        Check("the spliced block keeps the capture time",
              TiffText(splicedBlock, ExifComposer.TagDateTimeOriginal) == "2024:05:17 10:30:00");
        Check("the spliced block keeps the GPS position",
              splicedBlock is not null
              && FindTiffEntry(splicedBlock, ExifComposer.TagGpsLatitude, out var keptType,
                               out var keptCount, out _, out _)
              && keptType == 5 && keptCount == 3);
        var read = codec.ReadMetadataAsync(spliced).GetAwaiter().GetResult();
        Check("the decoder reads the composed model",
              Text(read, "System.Photo.CameraModel") == "RS-Compose");
        // The codec only asks for the allowlist, so the rest is read from the
        // same decoder directly: the block must satisfy a real EXIF reader,
        // not only the parser that wrote it.
        var decoded = DecodeProperties(spliced, new[]
        {
            "System.Photo.DateTaken",
            "System.Photo.ExposureTime",
            "System.Photo.FNumber",
            "System.Photo.LensModel",
            "System.GPS.Latitude",
            "System.GPS.Longitude",
        }).GetAwaiter().GetResult();
        var capture = decoded.TryGetValue("System.Photo.DateTaken", out var taken)
            ? taken.Value switch
            {
                DateTime date => (DateTime?)date,
                DateTimeOffset offset => offset.DateTime,
                _ => null,
            }
            : null;
        Check("the decoder reads the composed capture date",
              capture is { Year: 2024, Month: 5, Day: 17, Hour: 10, Minute: 30 });
        Check("the decoder reads the composed exposure",
              decoded.TryGetValue("System.Photo.ExposureTime", out var exposure)
              && exposure.Value is double seconds && Math.Abs(seconds - 0.008) < 0.0001);
        Check("the decoder reads the composed aperture",
              decoded.TryGetValue("System.Photo.FNumber", out var aperture)
              && aperture.Value is double fNumber && Math.Abs(fNumber - 2.8) < 0.01);
        Check("the decoder reads the composed lens",
              decoded.TryGetValue("System.Photo.LensModel", out var lens)
              && lens.Value is string name && name == "RF 50mm F1.8");
        var latitude = decoded.TryGetValue("System.GPS.Latitude", out var rawLatitude)
            && rawLatitude.Value is double[] { Length: 3 } parts
            && Math.Abs(parts[0] - 35) < 0.001
            && Math.Abs(parts[1] - 41) < 0.001
            && Math.Abs(parts[2] - 12) < 0.001;
        if (capture is null)
        {
            Describe(decoded, "System.Photo.DateTaken");
        }

        // WIC's WinRT surface exposes no GPS for JPEG at all: this file, and a
        // JPEG macOS ImageIO wrote with a GPS IFD, both report the property
        // absent. So the block is gated through the parser above and an
        // independent reader (see WINDOWS_FORMAT_AUDIT.md), and the WIC answer
        // is printed as a diagnostic instead of asserted.
        var foreign = Path.Combine(RepoRoot(),
                                   "Windows/RetouchStudio.Tests/Fixtures/camera-gps.jpg");
        var foreignProperties = DecodeProperties(foreign, new[]
        {
            "System.GPS.Latitude",
            "System.Photo.DateTaken",
        }).GetAwaiter().GetResult();
        Console.WriteLine($"  composed GPS through WIC: {(latitude ? "kept" : "absent")}");
        Console.WriteLine("  third-party GPS file:");
        Describe(foreignProperties, "System.GPS.Latitude");
        Describe(foreignProperties, "System.Photo.DateTaken");

        // A TIFF source has no APP1 or eXIf block to copy, so the export path
        // must compose one from the properties the decoder reports for it.
        var tiff = Path.Combine(root, "compose-source.tiff");
        codec.EncodeAsync(image, tiff, "tiff", 1.0,
                          new ImageMetadata(new Dictionary<string, object>
                          {
                              ["System.Photo.CameraModel"] = "RS-Tiff",
                          }), stripPrivacyMetadata: false).GetAwaiter().GetResult();
        using var session = ProjectSession.Create(tiff);
        var exported = Path.Combine(root, "compose-export.jpg");
        ExportRunner.ExportAsync(session, codec, exported, "jpeg", 0.9, 0,
                                 stripPrivacyMetadata: false).GetAwaiter().GetResult();
        var carried = MetadataCarry.ReadExif(exported);
        var carriedSize = codec.ReadSizeAsync(exported).GetAwaiter().GetResult();
        Check("a TIFF source exports a composed EXIF block",
              TiffText(carried, 0x0110) == "RS-Tiff");
        Check("the composed EXIF names the exported frame",
              TiffNumber(carried, 0xA002) == carriedSize.Width
              && TiffNumber(carried, 0xA003) == carriedSize.Height);
    }

    /// <summary>
    /// One Photoshop image resource: the 8BIM signature, the id, an empty
    /// Pascal name padded to an even width, the data length and the data,
    /// padded as the format requires.
    /// </summary>
    private static byte[] BuildResource(ushort id, byte[] data)
    {
        var resource = new byte[12 + data.Length + (data.Length % 2)];
        resource[0] = (byte)'8';
        resource[1] = (byte)'B';
        resource[2] = (byte)'I';
        resource[3] = (byte)'M';
        resource[4] = (byte)(id >> 8);
        resource[5] = (byte)id;
        resource[6] = 0;
        resource[8] = (byte)(data.Length >> 24);
        resource[9] = (byte)(data.Length >> 16);
        resource[10] = (byte)(data.Length >> 8);
        resource[11] = (byte)data.Length;
        data.CopyTo(resource, 12);
        return resource;
    }

    /// <summary>An IPTC IIM dataset: 0x1C, record 2, dataset 5 (Object Name).</summary>
    private static byte[] IptcTitle(string text)
    {
        var bytes = Encoding.ASCII.GetBytes(text);
        var dataset = new byte[5 + bytes.Length];
        dataset[0] = 0x1C;
        dataset[1] = 0x02;
        dataset[2] = 0x05;
        dataset[3] = (byte)(bytes.Length >> 8);
        dataset[4] = (byte)bytes.Length;
        bytes.CopyTo(dataset, 5);
        return dataset;
    }

    private static byte[] Join(params byte[][] parts)
    {
        var joined = new byte[parts.Sum(part => part.Length)];
        var at = 0;
        foreach (var part in parts)
        {
            part.CopyTo(joined, at);
            at += part.Length;
        }
        return joined;
    }

    /// <summary>Splices an APP13 segment after the JPEG's APP0, where a reader looks.</summary>
    private static void InsertApp13(string path, byte[] resources)
    {
        var file = File.ReadAllBytes(path);
        var at = 2;
        if (file.Length >= 6 && file[2] == 0xFF && file[3] == 0xE0)
        {
            at = 4 + ((file[4] << 8) | file[5]);
        }
        var signature = Encoding.ASCII.GetBytes("Photoshop 3.0\0");
        var segment = signature.Length + resources.Length + 2;
        using var output = new MemoryStream();
        output.Write(file, 0, at);
        output.WriteByte(0xFF);
        output.WriteByte(0xED);
        output.WriteByte((byte)(segment >> 8));
        output.WriteByte((byte)segment);
        output.Write(signature, 0, signature.Length);
        output.Write(resources, 0, resources.Length);
        output.Write(file, at, file.Length - at);
        File.WriteAllBytes(path, output.ToArray());
    }

    private static byte[] BuildExif(ushort orientation, int width, int height)
    {
        var make = Encoding.ASCII.GetBytes("Retouch\0");
        var model = Encoding.ASCII.GetBytes("RS-Carry\0");
        var date = Encoding.ASCII.GetBytes("2024:05:17 10:30:00\0");
        const int ifd0 = 8;
        const int entries = 5;
        var dataOffset = ifd0 + 2 + 12 * entries + 4;
        var makeOffset = dataOffset;
        var modelOffset = makeOffset + make.Length;
        var dateOffset = modelOffset + model.Length;
        var exifOffset = dateOffset + date.Length;
        if ((exifOffset & 1) != 0)
        {
            exifOffset++;
        }
        var tiff = new byte[exifOffset + 2 + 12 * 3 + 4];
        tiff[0] = (byte)'I';
        tiff[1] = (byte)'I';
        WriteTiffU16(tiff, 2, 42, little: true);
        WriteTiffU32(tiff, 4, ifd0, little: true);
        WriteTiffU16(tiff, ifd0, entries, little: true);
        var at = ifd0 + 2;
        TiffEntry(tiff, at, 0x010F, 2, (uint)make.Length, (uint)makeOffset);
        at += 12;
        TiffEntry(tiff, at, 0x0110, 2, (uint)model.Length, (uint)modelOffset);
        at += 12;
        TiffEntry(tiff, at, 0x0112, 3, 1, orientation);
        at += 12;
        TiffEntry(tiff, at, 0x0132, 2, (uint)date.Length, (uint)dateOffset);
        at += 12;
        TiffEntry(tiff, at, 0x8769, 4, 1, (uint)exifOffset);
        make.CopyTo(tiff, makeOffset);
        model.CopyTo(tiff, modelOffset);
        date.CopyTo(tiff, dateOffset);
        WriteTiffU16(tiff, exifOffset, 3, little: true);
        var exifEntry = exifOffset + 2;
        TiffEntry(tiff, exifEntry, 0xA001, 3, 1, 1);
        exifEntry += 12;
        TiffEntry(tiff, exifEntry, 0xA002, 4, 1, (uint)width);
        exifEntry += 12;
        TiffEntry(tiff, exifEntry, 0xA003, 4, 1, (uint)height);
        return tiff;
    }

    private static void TiffEntry(byte[] tiff, int at, ushort tag, ushort type,
                                  uint count, uint value)
    {
        WriteTiffU16(tiff, at, tag, little: true);
        WriteTiffU16(tiff, at + 2, type, little: true);
        WriteTiffU32(tiff, at + 4, count, little: true);
        WriteTiffU32(tiff, at + 8, value, little: true);
    }

    private static long? TiffNumber(byte[]? tiff, ushort tag)
    {
        if (tiff is null
            || !FindTiffEntry(tiff, tag, out var type, out _, out var entry, out var little))
        {
            return null;
        }
        return type switch
        {
            3 => (long)ReadTiffU16(tiff, entry + 8, little),
            4 => (long)ReadTiffU32(tiff, entry + 8, little),
            _ => (long?)null,
        };
    }

    private static string? TiffText(byte[]? tiff, ushort tag)
    {
        if (tiff is null
            || !FindTiffEntry(tiff, tag, out var type, out var count, out var entry, out var little)
            || type != 2 || count == 0 || count > 256)
        {
            return null;
        }
        var start = count <= 4
            ? (long)(entry + 8)
            : ReadTiffU32(tiff, entry + 8, little);
        if (start > int.MaxValue || start + count > tiff.Length)
        {
            return null;
        }
        return Encoding.ASCII.GetString(tiff, (int)start, (int)count).TrimEnd('\0');
    }

    private static bool FindTiffEntry(byte[] tiff, ushort wanted, out ushort type,
                                      out uint count, out int entry, out bool little)
    {
        type = 0;
        count = 0;
        entry = -1;
        little = tiff.Length > 1 && tiff[0] == (byte)'I';
        if (tiff.Length < 8 || ReadTiffU16(tiff, 2, little) != 42)
        {
            return false;
        }
        // IFD0, then the Exif and GPS sub-IFDs it points at; no directory is
        // visited twice, so a self-referential pointer cannot loop.
        var pending = new Queue<uint>();
        pending.Enqueue(ReadTiffU32(tiff, 4, little));
        var visited = new HashSet<uint>();
        while (pending.Count > 0 && visited.Count < 4)
        {
            var ifd = pending.Dequeue();
            if (!visited.Add(ifd) || ifd > int.MaxValue || (long)ifd + 2 > tiff.Length)
            {
                continue;
            }
            var at = (int)ifd;
            var total = ReadTiffU16(tiff, at, little);
            if (total > 4096 || (long)at + 2 + 12L * total > tiff.Length)
            {
                continue;
            }
            for (var index = 0; index < total; index++)
            {
                var candidate = at + 2 + 12 * index;
                var tag = ReadTiffU16(tiff, candidate, little);
                if (tag == wanted)
                {
                    type = ReadTiffU16(tiff, candidate + 2, little);
                    count = ReadTiffU32(tiff, candidate + 4, little);
                    entry = candidate;
                    return true;
                }
                if ((tag == 0x8769 || tag == 0x8825)
                    && ReadTiffU16(tiff, candidate + 2, little) == 4
                    && ReadTiffU32(tiff, candidate + 4, little) >= 1)
                {
                    pending.Enqueue(ReadTiffU32(tiff, candidate + 8, little));
                }
            }
        }
        return false;
    }

    private static ushort ReadTiffU16(byte[] bytes, int offset, bool little)
    {
        if (offset < 0 || offset + 2 > bytes.Length)
        {
            return 0;
        }
        return little
            ? (ushort)(bytes[offset] | (bytes[offset + 1] << 8))
            : (ushort)((bytes[offset] << 8) | bytes[offset + 1]);
    }

    private static uint ReadTiffU32(byte[] bytes, int offset, bool little)
    {
        if (offset < 0 || offset + 4 > bytes.Length)
        {
            return 0;
        }
        return little
            ? (uint)bytes[offset] | ((uint)bytes[offset + 1] << 8)
              | ((uint)bytes[offset + 2] << 16) | ((uint)bytes[offset + 3] << 24)
            : ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16)
              | ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];
    }

    private static void WriteTiffU16(byte[] bytes, int offset, ushort value, bool little)
    {
        if (little)
        {
            bytes[offset] = (byte)value;
            bytes[offset + 1] = (byte)(value >> 8);
        }
        else
        {
            bytes[offset] = (byte)(value >> 8);
            bytes[offset + 1] = (byte)value;
        }
    }

    private static void WriteTiffU32(byte[] bytes, int offset, uint value, bool little)
    {
        if (little)
        {
            bytes[offset] = (byte)value;
            bytes[offset + 1] = (byte)(value >> 8);
            bytes[offset + 2] = (byte)(value >> 16);
            bytes[offset + 3] = (byte)(value >> 24);
        }
        else
        {
            bytes[offset] = (byte)(value >> 24);
            bytes[offset + 1] = (byte)(value >> 16);
            bytes[offset + 2] = (byte)(value >> 8);
            bytes[offset + 3] = (byte)value;
        }
    }

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

        var v5Path = Path.Combine(repo, "Tests/Fixtures/ProjectV5/project-v5-full.retouch");
        var v5Fixture = JsonNode.Parse(File.ReadAllText(v5Path))!;
        using (var session = ProjectSession.Open(v5Path))
        {
            var model = session.Document;
            Check("a macOS v5 project opens as v5", model.Version == 5);
            Check("the masks reach the Windows document",
                  model.Root["masks"] is JsonArray masks && masks.Count == 2);
            Check("the mask's face association reaches the Windows document",
                  model.Root["masks"]![0]!["faceId"]!.GetValue<string>()
                  == "11111111-1111-4111-8111-111111111111");
            Check("a masked project names the edit this host cannot render",
                  model.UnsupportedEdits.Contains("masked selections"));

            var savedPath = Path.Combine(root, "from-macos-v5.retouch");
            session.Save(savedPath);
            var saved = JsonNode.Parse(File.ReadAllText(savedPath))!;
            Check("a saved v5 project keeps every record",
                  JsonNode.DeepEquals(saved, v5Fixture));
            Check("a v5 save keeps the mask ids",
                  saved["masks"]![0]!["id"]!.GetValue<string>()
                  == "22222222-2222-4222-8222-222222222222");
        }
    }

    /// <summary>
    /// WP-5 / R-5 on Windows: an autosave slot replaced atomically, immutable
    /// candidates no decision can overwrite, launch preparation that preserves
    /// every unresolved copy, and a restore order proved at each crash point by
    /// injected failures.
    /// </summary>
    private static void Recovery(string root)
    {
        var photo = Path.Combine(root, "recovery-photo.png");
        var otherPhoto = Path.Combine(root, "recovery-other.png");
        File.WriteAllBytes(photo, new byte[] { 1, 2, 3, 4, 5, 6 });
        File.WriteAllBytes(otherPhoto, new byte[] { 9, 9, 9 });
        var context = Encoding.UTF8.GetBytes("""{"version":4,"requiredFeatures":["futureMask"]}""");
        var at = new DateTimeOffset(2026, 11, 14, 10, 30, 0, TimeSpan.Zero);

        static byte[] ProjectFor(string imagePath, Action<JsonObject>? customize = null)
        {
            var document = new JsonObject
            {
                ["version"] = 4,
                ["imagePath"] = imagePath,
                ["adjustments"] = new JsonObject(),
                ["exportFormat"] = "jpeg",
                ["exportQuality"] = 0.92,
            };
            customize?.Invoke(document);
            return Encoding.UTF8.GetBytes(document.ToJsonString());
        }

        static RecoverySnapshot SnapshotAt(byte[] project, byte[] context,
                                           string imagePath, DateTimeOffset savedAt)
            => RecoverySnapshot.Capture(project, context, imagePath, savedAt);

        var snapshot = SnapshotAt(ProjectFor(photo), context, photo, at);
        Check("a snapshot records the photo's size and date",
              snapshot.Source is { Bytes: 6 });
        var decoded = RecoverySnapshot.FromUtf8(snapshot.ToUtf8());
        Check("the document survives a snapshot round trip",
              decoded?.Document().ImagePath == photo);
        Check("the write context survives a snapshot round trip",
              decoded is not null
              && JsonNode.DeepEquals(JsonNode.Parse(decoded.Context), JsonNode.Parse(context)));
        Check("the saved time survives a snapshot round trip", decoded?.SavedAt == at);
        Check("the photo identity survives a snapshot round trip",
              decoded?.Source == snapshot.Source);
        Check("an unchanged photo is recognised as the snapshot's photo",
              decoded?.SourceState() == RecoverySourceState.Available);
        var noPhoto = SnapshotAt(ProjectFor(Path.Combine(root, "gone.png")), context,
                                 Path.Combine(root, "gone.png"), at);
        Check("a snapshot of a missing photo records no identity, and says so",
              noPhoto.Source is null && noPhoto.SourceState() == RecoverySourceState.Missing);
        var changed = SnapshotAt(ProjectFor(otherPhoto), context, otherPhoto, at);
        File.AppendAllText(otherPhoto, "changed");
        Check("a photo replaced at the same path is noticed",
              changed.SourceState() == RecoverySourceState.Changed);

        var future = RecoverySnapshot.Capture(
            ProjectFor(photo, doc => doc["futureField"] = true),
            context, photo, at);
        var futureCopy = RecoverySnapshot.FromUtf8(future.ToUtf8());
        Check("an unknown project key survives recovery",
              futureCopy?.Document().Root["futureField"]?.GetValue<bool>() == true);
        Check("a non-snapshot file is refused, not thrown on",
              RecoverySnapshot.FromUtf8(Encoding.UTF8.GetBytes("{ not json")) is null
              && RecoverySnapshot.FromUtf8(Encoding.UTF8.GetBytes("""{"version":1}""")) is null);

        var store = new RecoveryStore(Path.Combine(root, "recovery-store"));
        Check("an autosave writes the working slot",
              store.WriteWorking(snapshot, out var written) && written is not null);
        Check("the working slot leaves no temporary file",
              File.Exists(store.WorkingPath) && !File.Exists(store.WorkingPath + ".tmp"));
        var read = store.ReadWorking();
        Check("the working slot reads back the document that was written",
              read is not null
              && JsonNode.DeepEquals(JsonNode.Parse(read.Project), JsonNode.Parse(snapshot.Project))
              && JsonNode.DeepEquals(JsonNode.Parse(read.Context), JsonNode.Parse(context)));
        store.WriteWorking(SnapshotAt(ProjectFor(photo), context, photo, at.AddMilliseconds(-500)),
                           out var second);
        Check("autosave time never goes backwards",
              second is not null && read is not null && second.SavedAt > read.SavedAt);

        var emptyStore = new RecoveryStore(Path.Combine(root, "recovery-empty"));
        Check("a clean launch lists no copies", emptyStore.PrepareForLaunch().Count == 0);

        var crashStore = new RecoveryStore(Path.Combine(root, "recovery-crash"));
        crashStore.WriteWorking(SnapshotAt(
            ProjectFor(photo, doc => doc["adjustments"]!["exposure"] = 1),
            context, photo, at), out _);
        var liftA = crashStore.PrepareForLaunch();
        Check("a launch lifts the crashed document into a candidate",
              liftA.Count == 1 && !File.Exists(crashStore.WorkingPath)
              && File.Exists(liftA[0].Path)
              && RecoveryStore.IsCandidateFileName(Path.GetFileName(liftA[0].Path)));
        crashStore.WriteWorking(SnapshotAt(
            ProjectFor(photo, doc => doc["adjustments"]!["exposure"] = 2),
            context, photo, at.AddMinutes(1)), out _);
        var liftB = crashStore.PrepareForLaunch();
        Check("each crashed document keeps its own independent copy", liftB.Count == 2);
        Check("candidates are listed oldest first",
              liftB[0].Snapshot.Document().Adjustment("exposure") == 1
              && liftB[1].Snapshot.Document().Adjustment("exposure") == 2);
        Check("a later autosave cannot change an earlier candidate",
              File.Exists(liftA[0].Path)
              && liftA[0].Snapshot.Document().Adjustment("exposure") == 1);

        var candidatesDirectory = Path.GetDirectoryName(liftA[0].Path)!;
        File.WriteAllBytes(Path.Combine(candidatesDirectory, $"5-{Guid.NewGuid():N}.retouch"),
                           Encoding.UTF8.GetBytes("{ not json"));
        File.WriteAllText(crashStore.WorkingPath, "{ not json");
        var afterCorrupt = crashStore.PrepareForLaunch();
        Check("a corrupt candidate is quarantined and not listed", afterCorrupt.Count == 2);
        Check("a corrupt working slot is quarantined and the slot is freed",
              !File.Exists(crashStore.WorkingPath));
        Check("quarantine keeps the unreadable bytes",
              Directory.GetFiles(Path.Combine(crashStore.Directory, "quarantine")).Length == 2);

        crashStore.InjectedFailures.Add(RecoveryStore.Failure.Quarantine);
        File.WriteAllText(crashStore.WorkingPath, "{ broken");
        crashStore.PrepareForLaunch();
        Check("a copy that cannot be quarantined stays in place",
              File.Exists(crashStore.WorkingPath)
              && File.ReadAllText(crashStore.WorkingPath) == "{ broken");
        crashStore.InjectedFailures.Clear();

        var migrateStore = new RecoveryStore(Path.Combine(root, "recovery-migrate"));
        migrateStore.WriteWorking(snapshot, out _);
        migrateStore.InjectedFailures.Add(RecoveryStore.Failure.Migrate);
        var stuck = migrateStore.PrepareForLaunch();
        Check("a working slot that cannot be lifted stays whole and is offered",
              File.Exists(migrateStore.WorkingPath) && stuck.Count == 1
              && stuck[0].Path == migrateStore.WorkingPath);
        Check("restoring a slot that could not be lifted keeps it whole",
              migrateStore.Restore(stuck[0]) && File.Exists(migrateStore.WorkingPath));
        migrateStore.InjectedFailures.Clear();

        var restoreStore = new RecoveryStore(Path.Combine(root, "recovery-restore"));
        restoreStore.WriteWorking(snapshot, out _);
        var restoreList = restoreStore.PrepareForLaunch();
        Check("a restore writes the working copy and deletes the candidate",
              restoreStore.Restore(restoreList[0])
              && File.Exists(restoreStore.WorkingPath)
              && !File.Exists(restoreList[0].Path));
        Check("the restored working copy is the candidate's document",
              restoreStore.ReadWorking() is { } restored
              && JsonNode.DeepEquals(JsonNode.Parse(restored.Project),
                                     JsonNode.Parse(restoreList[0].Snapshot.Project)));

        var crashRestore = new RecoveryStore(Path.Combine(root, "recovery-crash-restore"));
        crashRestore.WriteWorking(snapshot, out _);
        var crashList = crashRestore.PrepareForLaunch();
        crashRestore.InjectedFailures.Add(RecoveryStore.Failure.WorkingWrite);
        Check("a crash before the restore write leaves the candidate",
              !crashRestore.Restore(crashList[0]) && File.Exists(crashList[0].Path));
        crashRestore.InjectedFailures.Clear();
        crashRestore.InjectedFailures.Add(RecoveryStore.Failure.CandidateRemove);
        Check("a crash after the restore write leaves both complete copies",
              !crashRestore.Restore(crashList[0])
              && File.Exists(crashList[0].Path)
              && File.Exists(crashRestore.WorkingPath));
        crashRestore.InjectedFailures.Clear();

        var discardStore = new RecoveryStore(Path.Combine(root, "recovery-discard"));
        discardStore.WriteWorking(SnapshotAt(ProjectFor(photo), context, photo, at), out _);
        var discardA = discardStore.PrepareForLaunch();
        discardStore.WriteWorking(SnapshotAt(ProjectFor(photo), context, photo, at.AddMinutes(1)), out _);
        var discardB = discardStore.PrepareForLaunch();
        Check("discarding one copy leaves the other",
              discardA[0].Path == discardB[0].Path
              && discardStore.Discard(discardB[0])
              && !File.Exists(discardB[0].Path)
              && File.Exists(discardB[1].Path));

        var missingCandidate = new RecoveryStore.Candidate(
            Path.Combine(root, "never-written.retouch"), snapshot);
        var missingStore = new RecoveryStore(Path.Combine(root, "recovery-missing"));
        Check("a missing candidate is refused and nothing is written",
              !missingStore.Restore(missingCandidate)
              && !File.Exists(missingStore.WorkingPath));

        var ownStore = new RecoveryStore(Path.Combine(root, "recovery-own"));
        ownStore.WriteWorking(SnapshotAt(ProjectFor(photo), context, photo, at), out _);
        Check("another document's autosave is not dropped",
              !ownStore.RemoveWorking(otherPhoto) && File.Exists(ownStore.WorkingPath));
        Check("the document's own autosave is dropped",
              ownStore.RemoveWorking(photo) && !File.Exists(ownStore.WorkingPath));

        Check("a foreign file name is not a candidate",
              !RecoveryStore.IsCandidateFileName("working.retouch")
              && !RecoveryStore.IsCandidateFileName("1234-not-a-guid.retouch")
              && !RecoveryStore.IsCandidateFileName($"{Guid.NewGuid():N}.retouch"));
    }

    /// <summary>
    /// W5 on Windows: a photo-sized preview render, the same document exported
    /// through the 16-bit path, and a stress loop across crops, turns and both
    /// clarity signs. Budgets are safety nets for a pathological regression,
    /// not targets; every measured time is printed so a real slowdown shows in
    /// the CI log even when the budget still passes.
    /// </summary>
    private static void PerformanceAndStress(string root)
    {
        var codec = new WindowsImageCodec();
        var fixture = Path.Combine(RepoRoot(),
                                   "Tests/Corpus/Fixtures/F08_highres_portrait.png");
        using var session = ProjectSession.Create(fixture);
        foreach (var name in DocumentModel.GlobalAdjustmentNames)
        {
            session.Document.SetAdjustment(name, 40);
        }
        var previewSource = codec.DecodeAsync(fixture).GetAwaiter().GetResult()
                                 .ResizeLongEdge(1600);

        // Outside the measurement: the first call pays JIT and page-in.
        ExportRunner.RenderDocument(previewSource, session.Document);

        var runs = new List<double>();
        PixelBuffer? first = null;
        for (var run = 0; run < 5; run++)
        {
            var watch = Stopwatch.StartNew();
            var rendered = ExportRunner.RenderDocument(previewSource, session.Document);
            watch.Stop();
            runs.Add(watch.Elapsed.TotalMilliseconds);
            first ??= rendered;
        }
        var median = runs.OrderBy(value => value).ElementAt(runs.Count / 2);
        Console.WriteLine($"  perf preview {previewSource.Width}x{previewSource.Height} " +
                          $"nine sliders: median {median:0} ms " +
                          $"({string.Join(" ", runs.Select(value => value.ToString("0")))})");
        Check("a photo-sized adjusted preview renders inside 3 s", median < 3000);

        var again = ExportRunner.RenderDocument(previewSource, session.Document);
        Check("the same document renders the same pixels twice",
              again.Pixels.AsSpan().SequenceEqual(first!.Pixels));

        var exportPath = Path.Combine(root, "perf-export.png");
        var exportWatch = Stopwatch.StartNew();
        ExportRunner.ExportAsync(session, codec, exportPath, "png", 1.0, 0)
                     .GetAwaiter().GetResult();
        exportWatch.Stop();
        Console.WriteLine($"  perf 16-bit PNG export " +
                          $"{exportWatch.Elapsed.TotalMilliseconds:0} ms");
        Check("a 16-bit PNG export of the same document finishes inside 30 s",
              exportWatch.Elapsed.TotalSeconds < 30);

        // Forty documents that differ by crop, turn, straighten and the sign
        // of clarity, rendered one after another: no pass may fail on any of
        // them, and the last document must still be deterministic.
        var small = new PixelBuffer(256, 192);
        for (var y = 0; y < small.Height; y++)
        {
            for (var x = 0; x < small.Width; x++)
            {
                Put(small, x, y, (byte)x, (byte)(y * 255 / 191),
                    (byte)((x + y) % 256));
            }
        }
        var stress = new DocumentModel(new JsonObject());
        DocumentModel Prepare(int iteration)
        {
            var document = new DocumentModel(new JsonObject());
            for (var index = 0; index < DocumentModel.GlobalAdjustmentNames.Count; index++)
            {
                var value = (index * 53 + index * index * 11 + iteration * 17) % 201 - 100;
                document.SetAdjustment(DocumentModel.GlobalAdjustmentNames[index], value);
            }
            document.SetAdjustment("clarity", iteration % 2 == 0 ? 80 : -80);
            document.Crop = iteration % 3 == 0
                ? new CropValue(0.1, 0.1, 0.8, 0.7)
                : null;
            document.Orientation = (iteration % 4) switch
            {
                1 => OrientationValue.Identity.WithQuarterTurn(1),
                3 => OrientationValue.Identity.WithFlip(),
                _ => OrientationValue.Identity.WithAngle(iteration % 5 == 0 ? 3.5 : 0),
            };
            return document;
        }
        var intact = true;
        for (var iteration = 0; iteration < 40; iteration++)
        {
            stress = Prepare(iteration);
            var rendered = ExportRunner.RenderDocument(small, stress);
            intact &= rendered.Width > 0 && rendered.Height > 0
                      && rendered.Width * rendered.Height <= small.Width * small.Height;
        }
        Check("forty successive crop/turn/clarity documents all render", intact);
        var last = ExportRunner.RenderDocument(small, stress);
        var lastAgain = ExportRunner.RenderDocument(small, stress);
        Check("the last stress document renders the same pixels twice",
              last.Pixels.AsSpan().SequenceEqual(lastAgain.Pixels));
        var plain = ExportRunner.RenderDocument(small, Prepare(2));
        Check("an uncropped, unturned stress document keeps the photo size",
              plain.Width == small.Width && plain.Height == small.Height);

        // A long session at preview size: each of these renders allocates
        // buffers of tens of megabytes that must be collectable, so a host
        // that retained them would show up as heap growth well past the
        // ceiling. The measurement is a full collection on both sides.
        var heapBefore = GC.GetTotalMemory(forceFullCollection: true);
        for (var iteration = 40; iteration < 60; iteration++)
        {
            ExportRunner.RenderDocument(previewSource, Prepare(iteration));
        }
        var heapAfter = GC.GetTotalMemory(forceFullCollection: true);
        var growth = (heapAfter - heapBefore) / 1048576.0;
        Console.WriteLine($"  stress heap growth {growth:0.0} MB over twenty " +
                          $"preview renders");
        Check("twenty photo-sized renders keep the managed heap flat", growth < 150);

        // The managed heap says nothing about the decoder's native buffers, so
        // the process totals are printed next to it. They are recorded, not
        // gated: the runner's own baseline and the JIT move them run to run,
        // and a ceiling tight enough to catch a leak would fail on noise.
        using var process = Process.GetCurrentProcess();
        process.Refresh();
        Console.WriteLine($"  memory working set {process.WorkingSet64 / 1048576.0:0} MB, " +
                          $"peak {process.PeakWorkingSet64 / 1048576.0:0} MB " +
                          $"after sixty renders");
    }

    /// <summary>
    /// The host keeps macOS-only edits in the project file but cannot draw
    /// them, so it has to name them before an export writes pixels that lack
    /// them. The shared fixtures carry every kind; a new document carries none,
    /// even though its file writes the auto-retouch settings macOS also writes.
    /// </summary>
    private static void UnsupportedEditGuard(string root)
    {
        var repo = RepoRoot();
        using (var session = ProjectSession.Open(Path.Combine(
                   repo, "Tests/Fixtures/ProjectV4/project-v4-full.retouch")))
        {
            var edits = session.Document.UnsupportedEdits;
            Check("a macOS project names every edit this host cannot render",
                  edits.Count == 8
                  && edits.Contains("heal spots") && edits.Contains("stickers")
                  && edits.Contains("AI patches") && edits.Contains("analysis callouts")
                  && edits.Contains("skin retouching") && edits.Contains("face reshaping")
                  && edits.Contains("a look") && edits.Contains("film grain"));
        }
        using (var session = ProjectSession.Open(Path.Combine(
                   repo, "Tests/Fixtures/ProjectV3/project-v3-full.retouch")))
        {
            Check("a v3 project is checked the same way",
                  session.Document.UnsupportedEdits.Count == 8);
        }

        using (var session = ProjectSession.Create(Path.Combine(root, "fresh.png")))
        {
            Check("a new document names nothing, though its file carries the " +
                  "auto-retouch settings", session.Document.UnsupportedEdits.Count == 0);
            Check("the template still writes the settings macOS expects",
                  session.Document.Root["autoRetouchStrength"] is not null);
        }

        var empty = new DocumentModel(new JsonObject());
        Check("a project with no extra edits names none", empty.UnsupportedEdits.Count == 0);

        empty.Root["healSpots"] = new JsonArray();
        empty.Root["stickers"] = new JsonArray();
        empty.Root["aiEdits"] = new JsonArray();
        empty.Root["analysis"] = new JsonObject { ["isEnabled"] = false };
        empty.Root["autoRetouchStrength"] = 70;
        empty.Root["autoColorStrength"] = 100;
        Check("the auto-retouch settings are not edits", empty.UnsupportedEdits.Count == 0);

        empty.Root["stickers"] = new JsonArray(new JsonObject { ["kind"] = "heart" });
        Check("one sticker is enough to warn", empty.UnsupportedEdits.Count == 1
              && empty.UnsupportedEdits[0] == "stickers");

        var retouched = new DocumentModel(new JsonObject
        {
            ["adjustments"] = new JsonObject
            {
                ["smooth"] = 30.0,
                ["lookID"] = "kodachrome",
                ["backgroundImageAmount"] = 100.0,
            },
        });
        Check("a skin amount and a look are named",
              retouched.UnsupportedEdits.Count == 2
              && retouched.UnsupportedEdits.Contains("skin retouching")
              && retouched.UnsupportedEdits.Contains("a look"));
        Check("the background blend amount alone changes nothing",
              !retouched.UnsupportedEdits.Contains("background adjustments"));

        var replaced = new DocumentModel(new JsonObject
        {
            ["adjustments"] = new JsonObject { ["backgroundRemove"] = true },
        });
        Check("a removed background is named",
              replaced.UnsupportedEdits.Count == 1
              && replaced.UnsupportedEdits[0] == "background adjustments");

        var graded = new DocumentModel(new JsonObject
        {
            ["adjustments"] = new JsonObject
            {
                ["hslSaturation"] = new JsonArray(0.0, 0.0, 12.0, 0.0),
            },
        });
        Check("one HSL band amount is named",
              graded.UnsupportedEdits.Count == 1
              && graded.UnsupportedEdits[0] == "HSL colour");

        var renderable = new DocumentModel(new JsonObject
        {
            ["adjustments"] = new JsonObject
            {
                ["exposure"] = 20.0, ["contrast"] = 10.0, ["clarity"] = 15.0,
                ["texturePreserve"] = 70.0,
            },
        });
        Check("the nine renderable sliders are not edits",
              renderable.UnsupportedEdits.Count == 0);
    }

    /// <summary>
    /// A preset names the aspect of the finished frame, and the crop lives in
    /// that upright frame: the orientation is baked in first, as macOS does.
    /// The arithmetic is checked against literal fractions, two cases are
    /// rendered end to end, and one proves the order — after a quarter turn the
    /// frame's left half must be the photo's bottom half.
    /// </summary>
    private static void CropPresets()
    {
        var square = CropGeometry.Preset("square", 4000, 3000, 0);
        Check("a square preset crops three quarters of the width",
              square is { } s && Near(s.Width, 0.75) && Near(s.Height, 1)
              && Near(s.X, 0.125) && Near(s.Y, 0));

        var wide = CropGeometry.Preset("16:9", 4000, 3000, 0);
        Check("a 16:9 preset keeps the full width and crops the height",
              wide is { } w && Near(w.Width, 1) && Near(w.Height, 0.75)
              && Near(w.Y, 0.125));

        var widePortrait = CropGeometry.Preset("16:9", 2250, 4000, 0);
        var widePortraitTurned = CropGeometry.Preset("16:9", 2250, 4000, 1);
        Check("a 16:9 preset bands a 9:16 photo but crops nothing once turned",
              widePortrait is { } wp && Near(wp.Width, 1)
              && Near(wp.Height, 0.31640625) && Near(wp.Y, 0.341796875)
              && widePortraitTurned is { } wpt && Near(wpt.Width, 1)
              && Near(wpt.Height, 1) && Near(wpt.X, 0) && Near(wpt.Y, 0));

        Check("the original preset has no crop",
              CropGeometry.Preset("original", 4000, 3000, 0) is null);

        var readout = CropGeometry.PixelSize(new CropValue(0, 0, 0.5, 0.5), 4000, 3000, 0);
        var readoutTurned = CropGeometry.PixelSize(new CropValue(0, 0, 0.5, 0.5), 4000, 3000, 1);
        Check("the crop readout follows the upright frame",
              readout == (2000, 1500) && readoutTurned == (1500, 2000));
        Check("the crop readout never shows a zero side",
              CropGeometry.PixelSize(new CropValue(0, 0, CropGeometry.MinimumSide, 1),
                                     10, 10, 0) == (1, 10));

        var source = new PixelBuffer(256, 192);
        var document = new DocumentModel(new JsonObject())
        {
            Crop = CropGeometry.Preset("16:9", 256, 192, 1),
            Orientation = OrientationValue.Identity.WithQuarterTurn(1),
        };
        var rendered = ExportRunner.RenderDocument(source, document);
        Check("a 16:9 preset plus a quarter turn exports a 16:9 frame",
              rendered.Width == 192 && rendered.Height == 108);

        var photo = new PixelBuffer(256, 192);
        for (var y = 0; y < photo.Height; y++)
        {
            for (var x = 0; x < photo.Width; x++)
            {
                Put(photo, x, y, (byte)x, (byte)y, (byte)((x * 7 + y * 13) % 256));
            }
        }
        var half = new DocumentModel(new JsonObject())
        {
            Orientation = OrientationValue.Identity.WithQuarterTurn(1),
            Crop = new CropValue(0, 0, 0.5, 1),
        };
        var leftHalf = ExportRunner.RenderDocument(photo, half);
        var orderMatches = leftHalf.Width == 96 && leftHalf.Height == 256;
        for (var y = 0; orderMatches && y < 256; y++)
        {
            for (var x = 0; orderMatches && x < 96; x++)
            {
                orderMatches = Matches(leftHalf, x, y, photo, y, 191 - x);
            }
        }
        Check("a crop takes the upright frame's left half after a quarter turn",
              orderMatches);

        var deep = new PixelBuffer16(256, 192);
        for (var y = 0; y < deep.Height; y++)
        {
            for (var x = 0; x < deep.Width; x++)
            {
                var offset = (y * deep.Width + x) * 4;
                deep.Pixels[offset] = (ushort)((x * 7 + y * 13) % 256 * 257);
                deep.Pixels[offset + 1] = (ushort)(y * 257);
                deep.Pixels[offset + 2] = (ushort)(x * 257);
                deep.Pixels[offset + 3] = 65535;
            }
        }
        var deepHalf = ExportRunner.RenderDocument16(deep, half);
        var deepMatches = deepHalf.Width == 96 && deepHalf.Height == 256;
        for (var y = 0; y < 256 && deepMatches; y++)
        {
            for (var x = 0; x < 96 && deepMatches; x++)
            {
                var ai = (y * deepHalf.Width + x) * 4;
                var bi = ((191 - x) * deep.Width + y) * 4;
                for (var channel = 0; channel < 4 && deepMatches; channel++)
                {
                    deepMatches = deepHalf.Pixels[ai + channel] == deep.Pixels[bi + channel];
                }
            }
        }
        Check("the 16-bit export turns and crops the same frame", deepMatches);

        var leftWindow = new CropValue(0, 0, 0.5, 1);
        var promoted = CropGeometry.Rotate(leftWindow, 1);
        Check("a quarter turn moves the crop to the frame's top half",
              Near(promoted.X, 0) && Near(promoted.Y, 0)
              && Near(promoted.Width, 1) && Near(promoted.Height, 0.5));

        var roundTrip = CropGeometry.Rotate(new CropValue(0.1, 0.2, 0.3, 0.4), 4);
        Check("four turns leave the crop where it was",
              Near(roundTrip.X, 0.1) && Near(roundTrip.Y, 0.2)
              && Near(roundTrip.Width, 0.3) && Near(roundTrip.Height, 0.4));

        var mirrored = CropGeometry.Mirror(leftWindow);
        Check("a mirror moves the crop to the other side",
              Near(mirrored.X, 0.5) && Near(mirrored.Y, 0)
              && Near(mirrored.Width, 0.5) && Near(mirrored.Height, 1)
              && CropGeometry.IsFull(CropGeometry.Mirror(CropGeometry.Rotate(
                     new CropValue(0, 0, 1, 1), 1))));

        var follow = new DocumentModel(new JsonObject())
        {
            Orientation = OrientationValue.Identity.WithQuarterTurn(1),
            Crop = CropGeometry.Rotate(leftWindow, 1),
        };
        var followed = ExportRunner.RenderDocument(photo, follow);
        var follows = followed.Width == 192 && followed.Height == 128;
        for (var y = 0; y < 128 && follows; y++)
        {
            for (var x = 0; x < 192 && follows; x++)
            {
                follows = Matches(followed, x, y, photo, y, 191 - x);
            }
        }
        Check("a crop chosen before a turn keeps the same photo region", follows);
    }

    private static void OrientationComposition()
    {
        var photo = new PixelBuffer(256, 192);
        var deep = new PixelBuffer16(256, 192);
        for (var y = 0; y < photo.Height; y++)
        {
            for (var x = 0; x < photo.Width; x++)
            {
                Put(photo, x, y, (byte)x, (byte)y, (byte)((x * 7 + y * 13) % 256));
                var offset = (y * deep.Width + x) * 4;
                deep.Pixels[offset] = (ushort)((x * 7 + y * 13) % 256 * 257);
                deep.Pixels[offset + 1] = (ushort)(y * 257);
                deep.Pixels[offset + 2] = (ushort)(x * 257);
                deep.Pixels[offset + 3] = 65535;
            }
        }
        var document = new DocumentModel(new JsonObject())
        {
            Orientation = OrientationValue.Identity.WithQuarterTurn(1).WithFlip(),
        };
        var mirrored = ExportRunner.RenderDocument(photo, document);
        var mirrored16 = ExportRunner.RenderDocument16(deep, document);
        var compositionMatches = mirrored.Width == 192 && mirrored.Height == 256
                                 && mirrored16.Width == 192 && mirrored16.Height == 256;
        for (var y = 0; y < 256 && compositionMatches; y++)
        {
            for (var x = 0; x < 192 && compositionMatches; x++)
            {
                compositionMatches = Matches(mirrored, x, y, photo, y, x);
                var ai = (y * 192 + x) * 4;
                var bi = (x * 256 + y) * 4;
                for (var channel = 0; channel < 4 && compositionMatches; channel++)
                {
                    compositionMatches = mirrored16.Pixels[ai + channel] == deep.Pixels[bi + channel];
                }
            }
        }
        Check("a mirror follows the quarter turn in both depths", compositionMatches);

        var framed = new PixelBuffer(400, 400);
        for (var y = 0; y < 400; y++)
        {
            for (var x = 0; x < 400; x++)
            {
                Put(framed, x, y, (byte)(x / 2), (byte)(y / 2), 0);
            }
        }
        var straight = ExportRunner.RenderDocument(framed, new DocumentModel(new JsonObject())
        {
            Orientation = OrientationValue.Identity.WithAngle(20),
        });
        // Without the cover scale every corner samples the clamped edge, which
        // is the corner pixel itself; with it every corner is resampled from
        // inside the photo, so none of them can equal its source corner.
        var corners = new[] { (0, 0), (399, 0), (0, 399), (399, 399) };
        var covered = straight.Width == 400 && straight.Height == 400;
        foreach (var (x, y) in corners)
        {
            covered &= Get(straight, x, y) != Get(framed, x, y);
        }
        Check("a straighten covers every corner from inside the photo", covered);
    }

    private static bool Matches(PixelBuffer a, int ax, int ay, PixelBuffer b, int bx, int by)
    {
        var ai = (ay * a.Width + ax) * 4;
        var bi = (by * b.Width + bx) * 4;
        return a.Pixels[ai] == b.Pixels[bi]
               && a.Pixels[ai + 1] == b.Pixels[bi + 1]
               && a.Pixels[ai + 2] == b.Pixels[bi + 2]
               && a.Pixels[ai + 3] == b.Pixels[bi + 3];
    }

    /// <summary>
    /// Crop and orientation are pure pixel remaps, so each result is compared
    /// against an index written in this test rather than against the helper
    /// that produced it: a transpose, a mirrored turn or an off-by-one shows
    /// up here even though the geometry arithmetic would still look plausible.
    /// The 0.1/0.8/0.7 crop of a 256x192 frame rounds to a 205x134 box at
    /// (26, 19).
    /// </summary>
    private static void GeometryRenderParity()
    {
        var source = new PixelBuffer(256, 192);
        for (var y = 0; y < source.Height; y++)
        {
            for (var x = 0; x < source.Width; x++)
            {
                Put(source, x, y, (byte)x, (byte)y, (byte)((x * 7 + y * 13) % 256));
            }
        }

        // The reference is the same buffer through the identity pipeline, so a
        // no-op rounding difference cannot masquerade as a geometry fault.
        var plain = ExportRunner.RenderDocument(source, new DocumentModel(new JsonObject()));

        var cropped = ExportRunner.RenderDocument(source, new DocumentModel(new JsonObject())
        {
            Crop = new CropValue(0.1, 0.1, 0.8, 0.7),
        });
        Check("a crop renders the rounded 205x134 region",
              cropped.Width == 205 && cropped.Height == 134);
        var cropMatches = cropped.Width == 205 && cropped.Height == 134;
        for (var y = 0; cropMatches && y < cropped.Height; y++)
        {
            for (var x = 0; x < cropped.Width; x++)
            {
                cropMatches = Matches(cropped, x, y, plain, 26 + x, 19 + y);
            }
        }
        Check("every crop pixel is the photo pixel at that offset", cropMatches);

        var flipped = ExportRunner.RenderDocument(source, new DocumentModel(new JsonObject())
        {
            Orientation = OrientationValue.Identity.WithFlip(),
        });
        var flipMatches = flipped.Width == source.Width && flipped.Height == source.Height;
        for (var y = 0; flipMatches && y < source.Height; y++)
        {
            for (var x = 0; x < source.Width; x++)
            {
                flipMatches = Matches(flipped, x, y, plain, source.Width - 1 - x, y);
            }
        }
        Check("a horizontal flip mirrors each pixel across its row", flipMatches);

        var turned = ExportRunner.RenderDocument(source, new DocumentModel(new JsonObject())
        {
            Orientation = OrientationValue.Identity.WithQuarterTurn(1),
        });
        var turnMatches = turned.Width == source.Height && turned.Height == source.Width;
        for (var y = 0; turnMatches && y < turned.Height; y++)
        {
            for (var x = 0; x < turned.Width; x++)
            {
                turnMatches = Matches(turned, x, y, plain, y, source.Height - 1 - x);
            }
        }
        Check("a quarter turn maps each output pixel to its clockwise source", turnMatches);
    }

    private static bool Near(double value, double expected) =>
        Math.Abs(value - expected) < 1e-9;

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

    /// <summary>
    /// The live histogram: one buffer with a known colour in every pixel, so
    /// each channel's bin and the normalization to the tallest bin are literal
    /// numbers, plus luma computed with the Rec.709 weights macOS uses.
    /// </summary>
    private static void Histogram()
    {
        var image = new PixelBuffer(2, 2);
        Put(image, 0, 0, r: 0, g: 0, b: 0);
        Put(image, 1, 0, r: 255, g: 255, b: 255);
        Put(image, 0, 1, r: 255, g: 0, b: 0);
        Put(image, 1, 1, r: 0, g: 0, b: 0);

        var bins = HistogramSampler.Sample(image);
        Check("the histogram bins each channel and luma separately",
              bins.Count == 64 && bins.IsEmpty == false
              && Near(bins.Red[0], 2.0 / 3.0) && Near(bins.Red[63], 2.0 / 3.0)
              && Near(bins.Green[0], 1.0) && Near(bins.Green[63], 1.0 / 3.0)
              && Near(bins.Blue[0], 1.0) && Near(bins.Blue[63], 1.0 / 3.0)
              && Near(bins.Luma[0], 2.0 / 3.0) && Near(bins.Luma[63], 1.0 / 3.0)
              && Near(bins.Luma[13], 1.0 / 3.0));

        var coarse = HistogramSampler.Sample(image, 4);
        Check("a coarser histogram folds the same pixels into fewer bins",
              coarse.Count == 4 && Near(coarse.Green[0], 1.0)
              && Near(coarse.Green[3], 1.0 / 3.0)
              && Near(coarse.Red[0], 2.0 / 3.0) && Near(coarse.Red[3], 2.0 / 3.0));

        Check("a histogram of nothing is empty",
              HistogramSampler.Sample(image, 0).IsEmpty
              && HistogramBins.Empty.IsEmpty);
    }

    /// <summary>
    /// Canvas zoom and pan, with the numbers written out: a 800x600 photo fitted
    /// into a 1000x700 canvas, zoomed to 2x about the point (750, 350), must keep
    /// that point on the same image pixel, and a drag must stop at the canvas
    /// edge instead of losing the photo.
    /// </summary>
    private static void CanvasZoom()
    {
        const double fittedWidth = 800, fittedHeight = 600;
        const double canvasWidth = 1000, canvasHeight = 700;

        var view = new CanvasView();
        var start = view.ZoomText;
        view.ZoomIn(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        var afterOne = view.Zoom;
        view.ZoomIn(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        view.ZoomIn(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        view.ZoomIn(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        var atCeiling = view.Zoom;
        Check("zoom steps by 1.5 and stops at the 4x ceiling",
              start == "Fit" && Near(afterOne, 1.5) && Near(atCeiling, 4)
              && view.ZoomText == "400%");

        var anchored = new CanvasView();
        anchored.SetZoom(2, 750, 350, fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        var beforeOffset = (750 - canvasWidth / 2) / 1.0;
        var afterOffset = (750 - canvasWidth / 2 - anchored.PanX) / anchored.Zoom;
        Check("zooming about a point keeps the image pixel under it",
              Near(anchored.Zoom, 2) && Near(afterOffset, beforeOffset)
              && Near(anchored.PanX, -250) && Near(anchored.PanY, 0));

        var panned = new CanvasView();
        panned.SetZoom(2, 750, 350, fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        panned.PanBy(500, 500, fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        var crowded = (panned.PanX, panned.PanY);
        panned.PanBy(-1000, -1000, fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        Check("a drag stops at the canvas edge in both directions",
              Near(crowded.Item1, 250) && Near(crowded.Item2, 250)
              && Near(panned.PanX, -300) && Near(panned.PanY, -250));

        panned.SetZoomCentered(1, fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        Check("zooming back to fit drops the pan and the badge",
              Near(panned.Zoom, 1) && Near(panned.PanX, 0) && Near(panned.PanY, 0)
              && !panned.IsZoomed && panned.ZoomText == "Fit");

        var toggled = new CanvasView();
        toggled.Toggle(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        var doubled = toggled.Zoom;
        toggled.Toggle(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        Check("a double-click toggles between fit and 4x",
              Near(doubled, 4) && Near(toggled.Zoom, 1) && Near(toggled.PanX, 0));

        var stepped = new CanvasView();
        for (var step = 0; step < 8; step++)
        {
            stepped.ZoomOut(fittedWidth, fittedHeight, canvasWidth, canvasHeight);
        }
        Check("zoom out floors at fit",
              Near(stepped.Zoom, 1) && Near(stepped.PanX, 0) && Near(stepped.PanY, 0));
    }

    /// <summary>
    /// The before/after split: a drag is the pointer delta over the displayed
    /// width, added to where the split already was, and it cannot leave the
    /// photo — the same rule macOS applies.
    /// </summary>
    private static void CompareSplitChecks()
    {
        Check("the split starts at 45% of the displayed photo",
              Near(CompareSplit.DefaultFraction, 0.45));

        Check("a split drag is measured against the displayed width",
              Near(CompareSplit.Move(0.45, 250, 1000), 0.7)
              && Near(CompareSplit.Move(0.45, -450, 1000), 0)
              && Near(CompareSplit.Move(0.9, 500, 1000), 1));

        Check("a split on a zero-width photo keeps its fraction",
              Near(CompareSplit.Move(0.6, 100, 0), 0.6)
              && Near(CompareSplit.Clamp(-2), 0) && Near(CompareSplit.Clamp(3), 1));
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
