import unittest

import numpy as np

from retouch_ai_worker.engine import (_axis_plan, _axis_tiles,
                                      _pad_to_window, SWIN_WINDOW,
                                      UPSCALE_MAX_OUTPUT)


class UpscaleTilingTests(unittest.TestCase):
    def test_tiles_cover_the_axis_without_running_past_it(self):
        for length, tile, overlap in [(100, 256, 16), (256, 256, 16),
                                      (1000, 256, 16), (513, 128, 8),
                                      (17, 64, 4)]:
            spans = _axis_tiles(length, tile, overlap)
            self.assertEqual(spans[0][0], 0, (length, tile))
            self.assertEqual(spans[-1][1], length, (length, tile))
            for start, end in spans:
                self.assertLessEqual(end - start, tile)
                self.assertGreater(end, start)
            for (_, end), (start, _) in zip(spans, spans[1:]):
                self.assertLess(start, end, "gaps between tiles")

    def test_weights_partition_the_axis(self):
        # Blending the same value with complementary weights must reconstruct
        # it exactly; any dip means a seam.
        values = np.arange(1000, dtype=np.float32)
        spans = _axis_plan(1000, 256, 16)
        accumulated = np.zeros(1000, dtype=np.float32)
        weights = np.zeros(1000, dtype=np.float32)
        for start, end, weight in spans:
            accumulated[start:end] += values[start:end] * weight
            weights[start:end] += weight
        self.assertTrue(np.all(weights > 0))
        rebuilt = accumulated / weights
        self.assertTrue(np.allclose(rebuilt, values, atol=1e-4),
                        (rebuilt - values).max())

    def test_weights_fade_across_the_overlap(self):
        spans = _axis_plan(1000, 256, 16)
        start, end, weight = spans[1]
        previous_end = spans[0][1]
        overlap = previous_end - start
        self.assertGreater(overlap, 0)
        self.assertAlmostEqual(float(weight[0]), 0.0, places=6)
        self.assertAlmostEqual(float(weight[overlap - 1]),
                               1.0 - 1.0 / overlap, places=6)

    def test_small_image_is_one_tile(self):
        self.assertEqual(_axis_tiles(100, 256, 16), [(0, 100)])
        self.assertEqual(_axis_tiles(256, 256, 16), [(0, 256)])

    def test_output_budget_is_finite(self):
        self.assertGreater(UPSCALE_MAX_OUTPUT, 12_000_000)
        self.assertLess(UPSCALE_MAX_OUTPUT, 100_000_000)

    def test_window_padding_makes_any_tile_whole_windows(self):
        # 300x400 came back from the model as "shape [1, 180, 300, 400] is
        # invalid"; every tile has to be a multiple of the window size.
        source = np.random.default_rng(1).random((300, 400, 3), dtype=np.float32)
        padded, height, width = _pad_to_window(source)
        self.assertEqual((height, width), (300, 400))
        self.assertEqual(padded.shape[0] % SWIN_WINDOW, 0)
        self.assertEqual(padded.shape[1] % SWIN_WINDOW, 0)
        self.assertEqual(padded.shape[0], 304)
        self.assertEqual(padded.shape[1], 400)
        self.assertTrue(np.allclose(padded[:300, :400], source))

    def test_window_padding_is_a_no_op_when_already_aligned(self):
        source = np.zeros((256, 64, 3), dtype=np.float32)
        padded, height, width = _pad_to_window(source)
        self.assertEqual((height, width), (256, 64))
        self.assertEqual(padded.shape, source.shape)

    def test_every_tile_shape_is_aligned_after_padding(self):
        # Any photo shorter than a tile becomes that tile, so its own size has
        # to survive padding; taller photos are always cut at the tile size.
        for length, tile, overlap in [(300, 256, 16), (300, 512, 32),
                                      (100, 512, 32), (1000, 256, 16),
                                      (513, 128, 8)]:
            for start, end in _axis_tiles(length, tile, overlap):
                padded, height, width = _pad_to_window(
                    np.zeros((end - start, end - start, 3), dtype=np.float32))
                self.assertEqual(height, end - start)
                self.assertEqual(padded.shape[0] % SWIN_WINDOW, 0,
                                 (length, tile, start, end))


if __name__ == "__main__":
    unittest.main()
