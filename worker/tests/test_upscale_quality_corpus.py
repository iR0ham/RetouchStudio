"""The A1 corpus harness's meaning, tested without a worker or a fixture.

`tools/upscale_corpus.py` measures the owner's bar over private photos, so it
can never run in CI. What *can* run there is everything that decides what a
run means: the engine's tile boundaries, the degradation order, the median and
the exit-code mapping. All of it is exercised here on synthetic pixels, with
no socket, model or download.

The review of 2026-11-18 found three ways the harness could mislead: a control
comparison inside the verdict, seam bands computed at multiples of the tile
step only (missing the engine's clamped last start), and an upper-of-two-middles
"median". Each has a test below named for the defect it prevents.
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from PIL import Image, ImageFilter

TOOL = Path(__file__).resolve().parents[1] / "tools" / "upscale_corpus.py"


def load_tool():
    """Import the tool by path: it is a script, not an importable package."""
    spec = importlib.util.spec_from_file_location("upscale_corpus_under_test",
                                                  TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


corpus = load_tool()


class SeamBoundaryTests(unittest.TestCase):
    def test_boundaries_follow_the_engines_clamped_tile_rule(self):
        # engine._axis_tiles with UPSCALE_TILE = 256 and overlap = tile // 16:
        # starts run in steps of 240, and the last start is clamped to
        # length - 256 so every tile keeps full context.
        self.assertEqual(corpus.axis_tile_starts(567), [0, 240, 311])
        self.assertEqual(corpus.seam_boundaries(567), [960, 1244])
        self.assertEqual(corpus.seam_boundaries(1008),
                         [960, 1920, 2880, 3008])
        self.assertEqual(corpus.seam_boundaries(803), [960, 1920, 2188])
        self.assertEqual(corpus.seam_boundaries(1428),
                         [960, 1920, 2880, 3840, 4688])
        # A single-tile axis has no seam and therefore no band.
        self.assertEqual(corpus.seam_boundaries(256), [])

    def test_an_edge_only_band_is_not_a_seam(self):
        # The whole-frame rule would place a boundary at 960 on a 567-wide
        # axis that is only two tiles wide; the engine puts the second tile
        # at 311 (output 1244), so 1920 must not appear.
        self.assertNotIn(1920, corpus.seam_boundaries(567))

    def test_seam_psnr_masks_the_engine_boundaries_in_output_pixels(self):
        # The engine tiles the input, so a 2268-px output is a 567-px input
        # and its only x boundaries are 960 and 1244. A difference at 1250
        # must fall inside a band; one at 1500 must fall outside every band.
        reference = Image.new("RGB", (2268, 100), (128, 128, 128))
        inside = np.asarray(reference).copy()
        inside[50, 1250] = 0
        band = corpus.seam_psnr(reference, Image.fromarray(inside, "RGB"))
        self.assertIsNotNone(band)
        self.assertLess(band, 50.0)
        outside = np.asarray(reference).copy()
        outside[50, 1500] = 0
        self.assertEqual(
            corpus.seam_psnr(reference, Image.fromarray(outside, "RGB")),
            float("inf"))


class AggregateTests(unittest.TestCase):
    def test_even_counts_use_the_arithmetic_median(self):
        self.assertEqual(corpus.summarize([10, 20, 30, 40]),
                         {"minimum": 10, "mean": 25.0, "median": 25.0})
        self.assertEqual(corpus.summarize([]),
                         {"minimum": None, "mean": None, "median": None})


class JudgeTests(unittest.TestCase):
    def row(self, label, psnr, control, **extra):
        record = {"label": label, "psnr": psnr,
                  "controlBicubicPsnr": control, "modelVersion": "1.0.0",
                  "dimensionsExact": True}
        record.update(extra)
        return record

    def test_the_control_never_changes_the_exit_code(self):
        # The defect: a pair that lost to the bicubic control made the run
        # exit 1 even though the owner's bar was met on every image.
        records = [self.row("A", 26.0, 30.0), self.row("B", 25.0, 20.0)]
        bar, code, detail = corpus.judge(records, 24.0, None)
        self.assertEqual((bar, code), ("met", 0))
        self.assertEqual(records[0]["control"], "lose")
        self.assertEqual(records[1]["control"], "win")
        self.assertEqual(detail["outcomes"],
                         {"win": ["B"], "tie": [], "lose": ["A"]})

    def test_a_missed_bar_exits_one_even_when_the_control_is_beaten(self):
        records = [self.row("A", 23.9, 20.0)]
        bar, code, _ = corpus.judge(records, 24.0, None)
        self.assertEqual((bar, code), ("missed", 1))

    def test_an_unmeasurable_or_unapproved_image_claims_nothing(self):
        job_failed = {"label": "A", "error": "job ended as failed"}
        bar, code, detail = corpus.judge([job_failed], 24.0, None)
        self.assertEqual((bar, code), ("not-measured", 2))
        self.assertEqual(detail["notMeasured"], ["A"])
        wrong_version = [self.row("B", 30.0, 20.0, modelVersion="0.9.0")]
        self.assertEqual(corpus.judge(wrong_version, 24.0, None)[:2],
                         ("not-measured", 2))
        wrong_size = [{"label": "C", "dimensionsExact": False,
                       "controlBicubicPsnr": 20.0}]
        self.assertEqual(corpus.judge(wrong_size, 24.0, None)[:2],
                         ("not-measured", 2))
        # A measured miss is a bar verdict and outranks an unmeasured row.
        mixed = [self.row("D", 20.0, 20.0), job_failed]
        self.assertEqual(corpus.judge(mixed, 24.0, None)[:2], ("missed", 1))

    def test_the_bar_compares_the_unrounded_measurement(self):
        # 23.996 used to be recorded as 24.0 and counted as met.
        self.assertEqual(corpus.judge([self.row("A", 23.996, 20.0)],
                                      24.0, None)[:2], ("missed", 1))
        self.assertEqual(corpus.judge([self.row("B", 24.004, 20.0)],
                                      24.0, None)[:2], ("met", 0))

    def test_an_exact_match_meets_the_bar(self):
        # psnr() returns inf when the output equals the reference; that is a
        # measured pass, not an unmeasured row.
        self.assertEqual(corpus.judge([self.row("A", float("inf"), 20.0)],
                                      24.0, None)[:2], ("met", 0))


class LrDegradationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(7)
        pixels = np.full((256, 256, 3), 128, dtype=np.uint8)
        # A textured half, so blur, JPEG and noise have something to act on;
        # the left half stays flat and measures the noise floor on its own.
        pixels[:, 128:] = rng.integers(0, 256, (256, 128, 3), dtype=np.uint8)
        cls.reference = Image.fromarray(pixels, "RGB")

    def test_lr_is_blur_then_downscale_then_jpeg_then_noise(self):
        degraded, info = corpus.degrade(self.reference, "lr", 42)
        self.assertEqual(degraded.size, (64, 64))
        self.assertEqual(info["seed"], 42)
        self.assertEqual(info["jpegQuality"], 70)
        self.assertEqual(info["jpegSubsampling"], "4:2:0")
        self.assertIn("blur at reference resolution", info["order"])
        expected = self.reference.filter(
            ImageFilter.GaussianBlur(radius=corpus.BLUR_RADIUS))
        expected = expected.resize((64, 64), Image.BICUBIC)
        expected = corpus._jpeg_roundtrip(expected)
        expected = corpus._add_noise(expected, 42)
        self.assertTrue(np.array_equal(np.asarray(degraded),
                                       np.asarray(expected)))
        swapped = corpus._jpeg_roundtrip(
            self.reference.resize((64, 64), Image.BICUBIC))
        swapped = corpus._add_noise(swapped, 42)
        swapped = swapped.filter(
            ImageFilter.GaussianBlur(radius=corpus.BLUR_RADIUS))
        self.assertFalse(np.array_equal(np.asarray(degraded),
                                        np.asarray(swapped)))

    def test_noise_survives_the_downscale_only_in_lr(self):
        # The §8 defect: noise injected at the reference resolution is
        # averaged by the x4 downscale. `lr` injects it afterwards, so its
        # flat-patch spread is ~5 code values where `realistic` is ~1.
        lr, _ = corpus.degrade(self.reference, "lr", 42)
        realistic, _ = corpus.degrade(self.reference, "realistic", 42)
        bicubic, _ = corpus.degrade(self.reference, "bicubic", 42)
        lr_flat = np.asarray(lr)[:, :16].astype(np.float64).std()
        realistic_flat = np.asarray(realistic)[:, :16].astype(np.float64).std()
        bicubic_flat = np.asarray(bicubic)[:, :16].astype(np.float64).std()
        self.assertGreater(lr_flat, 4.0)
        self.assertLess(lr_flat, 6.0)
        self.assertLess(realistic_flat, 2.0)
        self.assertGreater(lr_flat, 3.0 * realistic_flat)
        # A plain downscale of a flat patch carries no noise at all.
        self.assertLess(bicubic_flat, 0.01)

    def test_the_pair_is_deterministic_per_seed(self):
        first, _ = corpus.degrade(self.reference, "lr", 5)
        again, _ = corpus.degrade(self.reference, "lr", 5)
        other, _ = corpus.degrade(self.reference, "lr", 6)
        self.assertTrue(np.array_equal(np.asarray(first), np.asarray(again)))
        self.assertFalse(np.array_equal(np.asarray(first), np.asarray(other)))


class SourceMetadataTests(unittest.TestCase):
    def test_describe_matches_the_acceptance_descriptor(self):
        image = Image.new("RGBA", (8, 6), (1, 2, 3, 4))
        image.getexif()[274] = 6
        described = corpus.describe(image, "test profile")
        self.assertEqual(described["width"], 8)
        self.assertEqual(described["height"], 6)
        self.assertEqual(described["bitDepth"], 8)
        self.assertEqual(described["channels"], 4)
        self.assertTrue(described["alpha"])
        self.assertEqual(described["exifOrientation"], 6)
        self.assertEqual(described["icc"], "test profile")


class RecordTests(unittest.TestCase):
    def test_the_record_separates_the_bar_from_the_control(self):
        row = {"label": "A", "psnr": 30.0, "controlBicubicPsnr": 20.0,
               "modelVersion": "1.0.0", "dimensionsExact": True}

        class StubClient:
            def __init__(self, path, timeout=0.0):
                self.closed = False

            def call(self, method, params=None):
                if method == "capability.list":
                    return {"result": {"capabilities": [
                        {"capabilityId": "upscale.4x", "state": "supported"}]}}
                return {"result": {"ok": True}}

            def close(self):
                self.closed = True

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "record.json"
            parser = corpus.build_parser()
            args = parser.parse_args(["--socket", "stub", "--out", str(out),
                                      "--sample", f"A={TOOL}",
                                      "--degradation", "lr",
                                      "--temp-dir", str(Path(tmp) / "temp")])
            samples = corpus.parse_samples(parser, args.sample)
            with mock.patch.object(corpus, "Client", StubClient), \
                    mock.patch.object(corpus, "run_sample",
                                      return_value=dict(row)):
                code = corpus.measure(args, samples)
            record = json.loads(out.read_text())

        self.assertEqual(code, 0)
        self.assertEqual(record["a1Bar"], "met")
        self.assertEqual(record["exitCode"], 0)
        self.assertEqual(record["bar"]["minPsnr"], 24.0)
        self.assertEqual(record["bar"]["source"],
                         "Decision A1 (owner), 2026-11-18")
        self.assertEqual(record["control"]["role"],
                         "diagnostic; never an exit-code input")
        self.assertEqual(record["control"]["outcomes"],
                         {"win": ["A"], "tie": [], "lose": []})
        self.assertEqual(record["images"][0]["a1"], "met")
        self.assertEqual(record["images"][0]["control"], "win")
        self.assertEqual(record["images"][0]["controlDeltaDb"], 10.0)
        self.assertEqual(record["aggregate"]["median"], 30.0)
        self.assertEqual(record["contract"]["renderingIntent"], 1)
        self.assertEqual(record["contract"]["degradationParameters"]
                         ["blurRadiusInputPixels"], 0.3)


class ExitCodeTests(unittest.TestCase):
    def _run(self, *arguments):
        return subprocess.run([sys.executable, str(TOOL), *arguments],
                              capture_output=True, text=True, timeout=120)

    def test_bad_input_and_unreachable_worker_exit_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            out = str(root / "record.json")
            missing = self._run("--socket", str(root / "none.sock"),
                                "--sample", f"A={root / 'absent.png'}",
                                "--out", out)
            self.assertEqual(missing.returncode, 2, missing.stderr)
            self.assertIn("not a file", missing.stderr)
            image = root / "ok.png"
            Image.new("RGB", (32, 32)).save(image)
            unreachable = self._run("--socket", str(root / "none.sock"),
                                    "--sample", f"A={image}", "--out", out)
            self.assertEqual(unreachable.returncode, 2, unreachable.stderr)
            self.assertIn("cannot connect", unreachable.stderr)

    def test_an_unexpected_failure_exits_three(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "ok.png"
            Image.new("RGB", (8, 8)).save(image)
            with mock.patch.object(corpus, "measure",
                                   side_effect=RuntimeError("boom")), \
                    mock.patch.object(corpus.traceback, "print_exc"):
                code = corpus.main(["--socket", str(Path(tmp) / "s.sock"),
                                    "--sample", f"A={image}",
                                    "--out", str(Path(tmp) / "o.json")])
        self.assertEqual(code, 3)


class ControlNoteTests(unittest.TestCase):
    def test_the_note_carries_this_runs_numbers(self):
        note = corpus.control_note(
            "bicubic", {"minimum": 20.0, "mean": 25.0, "median": 24.0},
            {"win": ["A"], "tie": [], "lose": ["B"]})
        self.assertIn("On the 2026-11-18 corpus", note)
        self.assertIn("This run: control minimum 20.00 dB, mean 25.00 dB",
                      note)
        self.assertIn("win 1, tie 0, lose 1", note)

    def test_a_run_with_nothing_measured_claims_no_numbers(self):
        note = corpus.control_note(
            "lr", {"minimum": None, "mean": None, "median": None},
            {"win": [], "tie": [], "lose": []})
        self.assertIn("measured no image", note)
        self.assertNotIn("This run: control minimum", note)


class RecordSafetyTests(unittest.TestCase):
    def test_non_finite_values_are_written_as_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "record.json"
            corpus.write_record(out, {"psnr": float("inf"),
                                      "nested": [float("nan"), 1.5]})
            text = out.read_text()
        self.assertNotIn("Infinity", text)
        self.assertNotIn("NaN", text)
        self.assertEqual(json.loads(text),
                         {"psnr": None, "nested": [None, 1.5]})


class _StubClient:
    def __init__(self, path, timeout=0.0):
        pass

    def call(self, method, params=None):
        if method == "capability.list":
            return {"result": {"capabilities": [
                {"capabilityId": "upscale.4x", "state": "supported"}]}}
        return {"result": {"ok": True}}

    def close(self):
        pass


class FailedSampleTests(unittest.TestCase):
    def _measure(self, tmp, sample):
        out = Path(tmp) / "record.json"
        parser = corpus.build_parser()
        args = parser.parse_args(["--socket", "stub", "--out", str(out),
                                  "--sample", f"A={sample}",
                                  "--temp-dir", str(Path(tmp) / "temp")])
        samples = corpus.parse_samples(parser, args.sample)
        with mock.patch.object(corpus, "Client", _StubClient):
            code = corpus.measure(args, samples)
        return code, json.loads(out.read_text())

    def test_a_provenance_failure_is_unmeasured_and_exits_two(self):
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / "ok.png"
            Image.new("RGB", (8, 8)).save(image)
            with mock.patch.object(
                    corpus, "run_sample",
                    side_effect=corpus.provenance.ProvenanceError(
                        "sidecar digest mismatch")):
                code, record = self._measure(tmp, image)
        self.assertEqual(code, 2)
        self.assertEqual(record["a1Bar"], "not-measured")
        self.assertEqual(record["exitCode"], 2)
        self.assertEqual(record["bar"]["notMeasuredImages"], ["A"])
        self.assertIn("sidecar digest mismatch", record["images"][0]["error"])

    def test_an_unreadable_fixture_is_recorded_not_a_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            broken = Path(tmp) / "broken.png"
            broken.write_text("not an image", encoding="utf-8")
            code, record = self._measure(tmp, broken)
        self.assertEqual(code, 2)
        self.assertEqual(record["a1Bar"], "not-measured")
        self.assertIn("cannot read", record["images"][0]["error"])


if __name__ == "__main__":
    unittest.main()
