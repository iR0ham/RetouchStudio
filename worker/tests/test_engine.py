import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from retouch_ai_worker.engine import Context, Engine, _square_box, composite, mask_policy, region_alpha
from retouch_ai_worker.protocol import INVALID_PARAMS, WorkerError

PACKAGE = Path(__file__).resolve().parent.parent / "retouch_ai_worker"


class MaskPolicyTests(unittest.TestCase):
    def test_small_object_uses_patch(self):
        self.assertEqual(mask_policy(0.01), "patch")
        self.assertEqual(mask_policy(0.06), "patch")

    def test_surrounding_mask_uses_full_frame(self):
        self.assertEqual(mask_policy(0.08), "full-frame")
        self.assertEqual(mask_policy(0.45), "full-frame")

    def test_huge_mask_is_refused(self):
        self.assertEqual(mask_policy(0.9), "too-large")


class CompositeTests(unittest.TestCase):
    def test_outside_region_is_byte_identical(self):
        original = np.zeros((64, 64, 3), dtype=np.uint8)
        generated = np.full((64, 64, 3), 255, dtype=np.uint8)
        mask = np.zeros((64, 64), dtype=np.uint8)
        mask[20:40, 20:40] = 255
        out, region = composite(original, generated, mask, dilate=2, feather=1)
        self.assertTrue(np.array_equal(out[~region], original[~region]))
        self.assertTrue(region[30, 30])
        self.assertGreater(out[30, 30].max(), 0)

    def test_empty_mask_changes_nothing(self):
        original = np.full((16, 16, 3), 7, dtype=np.uint8)
        generated = np.zeros_like(original)
        mask = np.zeros((16, 16), dtype=np.uint8)
        out, region = composite(original, generated, mask)
        self.assertFalse(region.any())
        self.assertTrue(np.array_equal(out, original))

    def test_alpha_never_exceeds_the_dilated_mask(self):
        import cv2

        mask = np.zeros((64, 64), dtype=np.uint8)
        mask[28:36, 28:36] = 255
        dilate = 3
        alpha = region_alpha(mask, dilate=dilate, feather=2)
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE,
                                          (dilate * 2 + 1, dilate * 2 + 1))
        dilated = cv2.dilate((mask > 127).astype(np.uint8), kernel).astype(bool)
        self.assertEqual(float(alpha[~dilated].max()), 0.0)
        self.assertGreater(float(alpha.max()), 0.9)
        self.assertTrue(np.all(alpha >= 0.0) and np.all(alpha <= 1.0))


class BoxTests(unittest.TestCase):
    def test_box_is_square_and_inside_the_image(self):
        mask = np.zeros((100, 80), dtype=np.uint8)
        mask[30:50, 60:79] = 255
        x0, y0, x1, y1 = _square_box(mask, 0.25, 80, 100)
        self.assertEqual(x1 - x0, y1 - y0)
        self.assertGreaterEqual(x0, 0)
        self.assertGreaterEqual(y0, 0)
        self.assertLessEqual(x1, 80)
        self.assertLessEqual(y1, 100)
        self.assertLess(x0, 60)
        self.assertGreaterEqual(x1, 79)


class FullFrameRoutingTests(unittest.TestCase):
    """An explicit full-frame request is a reimagine, not a measurement."""

    @staticmethod
    def _ctx(workdir: str) -> Context:
        return Context(job_id="test", workdir=Path(workdir),
                       cancel=lambda: False, progress=lambda event: None,
                       allow_roots=(Path(workdir),))

    def test_explicit_request_skips_the_mask(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.png"
            Image.new("RGB", (32, 24), (90, 120, 150)).save(source)
            engine = Engine.__new__(Engine)
            seen = {}

            def fake_full_frame(image, prompt, params, ctx, fraction):
                seen.update(prompt=prompt, fraction=fraction, shape=image.shape)
                return {"mode": "full-frame", "output": "stub"}

            engine._full_frame = fake_full_frame
            result = engine._job_patch_edit(
                {"image": {"path": str(source)}, "prompt": "golden hour",
                 "full_frame": True, "engine": "patch"},
                self._ctx(tmp))

            self.assertEqual(result["mode"], "full-frame")
            self.assertEqual(seen["prompt"], "golden hour")
            self.assertEqual(seen["fraction"], 1.0)
            self.assertEqual(seen["shape"], (24, 32, 3))

    def test_explicit_request_still_requires_a_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.png"
            Image.new("RGB", (8, 8)).save(source)
            with self.assertRaises(WorkerError) as caught:
                Engine.__new__(Engine)._job_patch_edit(
                    {"image": {"path": str(source)}, "full_frame": True},
                    self._ctx(tmp))
            self.assertEqual(caught.exception.code, INVALID_PARAMS)


class NoNetworkTests(unittest.TestCase):
    def test_job_path_has_no_network_code(self):
        for name in ("server.py", "engine.py", "transport.py", "protocol.py",
                     "catalog.py", "plan.py"):
            source = (PACKAGE / name).read_text("utf-8")
            for forbidden in ("urllib", "http.client", "requests", "socket.socket"):
                self.assertNotIn(forbidden, source, f"{name} imports {forbidden}")

    def test_server_does_not_import_the_downloader(self):
        source = (PACKAGE / "server.py").read_text("utf-8")
        self.assertNotIn("downloads", source)


if __name__ == "__main__":
    unittest.main()
