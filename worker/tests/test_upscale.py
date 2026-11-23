import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import numpy as np
from PIL import Image

from retouch_ai_worker import __version__, provenance
from retouch_ai_worker.capabilities import current_platform
from retouch_ai_worker.catalog import (APPROVED, LICENCE_READ_ON, REQUIRED_USE,
                                       STATED_BY_RIGHTS_HOLDER, ArtefactTerms,
                                       ModelEntry, ModelFile, PermittedUse)
from retouch_ai_worker.engine import (Cancelled, Context, Engine, _axis_plan,
                                      _axis_tiles, _pad_to_window, _quantise,
                                      SWIN_WINDOW, UPSCALE_BAND_ROWS,
                                      UPSCALE_MAX_OUTPUT)
from retouch_ai_worker.protocol import INTERNAL_ERROR, WorkerError

_TERMS = ArtefactTerms(
    use=REQUIRED_USE, can_acquire=True, can_redistribute=True, can_use=True,
    stated_by=STATED_BY_RIGHTS_HOLDER, evidence_url="https://example.test/L",
    read_on=LICENCE_READ_ON, verdict=APPROVED)
CLEARED_USE = PermittedUse(code=_TERMS, weights=_TERMS, training_data=_TERMS)


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


class _Tensor:
    """The slice of the torch tensor API the upscale loop touches, on numpy."""

    def __init__(self, array):
        self.array = np.asarray(array)

    def __getitem__(self, key):
        # numpy already understands `None`, ints and slice tuples.
        return _Tensor(self.array[key])

    def permute(self, *order):
        return _Tensor(np.transpose(self.array, order))

    def to(self, device):
        return self

    def clamp(self, low, high):
        return _Tensor(np.clip(self.array, low, high))

    def cpu(self):
        return self

    def numpy(self):
        return self.array


class _NoGrad:
    def __enter__(self):
        return None

    def __exit__(self, *exc):
        return False


class _FakeModel:
    """A stand-in 4x network: it repeats each pixel rather than predicting one."""

    def __init__(self, on_load=None):
        self.calls = 0
        self.device = None
        self.root = None
        self.on_load = on_load

    def from_pretrained(self, root, local_files_only=True):
        self.root = Path(root)
        self.local_files_only = local_files_only
        if self.on_load is not None:
            self.on_load()
        return self

    def to(self, device):
        self.device = device
        return self

    def eval(self):
        return self

    def __call__(self, tensor):
        self.calls += 1
        up = np.repeat(np.repeat(tensor.array, 4, axis=2), 4, axis=3) * 0.5
        return SimpleNamespace(reconstruction=_Tensor(up))


def _fake_torch(mps=True):
    return SimpleNamespace(
        from_numpy=lambda array: _Tensor(array), no_grad=_NoGrad,
        backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: mps)))


class _StubCatalog:
    """The catalog surface the upscaler uses, with digests the test owns.

    `require` is a trap: a job path that reaches it would load weights that were
    never hashed against the catalog.
    """

    def __init__(self, root, version=None):
        self.root = Path(root)
        self.verified = []
        self.model_root = self.root / "swin2sr-x4"
        if version is not None:
            self.model_root = self.model_root / version
        self.model_root.mkdir(parents=True, exist_ok=True)
        self.entry = ModelEntry(
            id="swin2sr-x4", name="Swin2SR x4", task="upscaling",
            license_id="Apache-2.0", permitted_use=CLEARED_USE, source="local",
            files=(ModelFile("pytorch_model.bin", "a" * 64, 48),))

    def get(self, model_id):
        return self.entry

    def require(self, model_id):
        raise AssertionError(f"{model_id} loaded without a checksum verification")

    def require_verified(self, model_id):
        self.verified.append(model_id)
        return self.model_root


class QuantiseTests(unittest.TestCase):
    """The band boundary is a loop boundary, never a value boundary."""

    def test_banded_quantiser_equals_the_whole_frame_expression(self):
        # Heights cover the empty and single-row cases, a value below one
        # band, exactly one band and a trailing partial band; the values run
        # outside [0, 1] so both sides exercise the clip.
        rng = np.random.default_rng(20261118)
        band = 7
        for rows in (0, 1, 6, 7, 8, 15):
            acc = rng.random((rows, 5, 3), dtype=np.float32) * 1.4 - 0.2
            weights = rng.random((rows, 5), dtype=np.float32) + 0.1
            expected = (np.clip(acc / weights[..., None], 0, 1) * 255
                        ).round().astype(np.uint8)
            actual = _quantise(acc.copy(), weights.copy(), band_rows=band)
            self.assertTrue(np.array_equal(actual, expected), rows)

        # The production band itself, with a trailing one-row band.
        rows = UPSCALE_BAND_ROWS + 1
        acc = rng.random((rows, 3, 3), dtype=np.float32) * 1.4 - 0.2
        weights = rng.random((rows, 3), dtype=np.float32) + 0.1
        expected = (np.clip(acc / weights[..., None], 0, 1) * 255
                    ).round().astype(np.uint8)
        self.assertTrue(np.array_equal(
            _quantise(acc.copy(), weights.copy()), expected))


class UpscaleJobTests(unittest.TestCase):
    """The upscale job against a fake torch: no models, no downloads, no GPU."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.inputs = self.tmp / "inputs"
        self.inputs.mkdir()
        self.workdir = self.tmp / "job"
        self.workdir.mkdir()
        source = np.zeros((32, 24, 3), dtype=np.uint8)
        source[..., 0] = 7
        self.image = self.inputs / "photo.png"
        Image.fromarray(source).save(self.image)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _run(self, model=None, mps=True, cancel=lambda: False, version=None,
             capability="upscale.4x"):
        model = model or _FakeModel()
        catalog = _StubCatalog(self.tmp / "models", version=version)
        engine = Engine(catalog, allow_roots=(self.inputs,))
        ctx = Context(job_id="job-1", workdir=self.workdir, cancel=cancel,
                      progress=lambda fields: None,
                      allow_roots=(self.inputs,), capability_id=capability)
        modules = {"torch": _fake_torch(mps),
                   "transformers": SimpleNamespace(
                       Swin2SRForImageSuperResolution=model)}
        with mock.patch.dict(sys.modules, modules):
            try:
                result = engine.run("upscale", {"image": {"path": str(self.image)}},
                                    ctx)
            except Cancelled as exc:
                return engine, catalog, model, None, exc
        return engine, catalog, model, result, None

    def _sidecar(self):
        return self.workdir / "upscaled.png.provenance.json"

    def test_job_returns_a_4x_artifact_and_records_the_verified_load(self):
        engine, catalog, model, result, error = self._run()
        self.assertIsNone(error)
        self.assertEqual(result["output_size"], [96, 128])
        self.assertEqual(result["image_size"], [24, 32])
        with Image.open(result["output"]) as artifact:
            self.assertEqual(artifact.size, (96, 128))
        self.assertEqual(catalog.verified, ["swin2sr-x4"])
        self.assertEqual(model.device, "mps")
        self.assertEqual(engine.execution_providers(), (["mps"], None))

    def test_sidecar_carries_every_field_the_contract_lists(self):
        _, _, _, result, error = self._run()
        self.assertIsNone(error)
        self.assertEqual(result["provenance"], str(self._sidecar()))
        doc = json.loads(self._sidecar().read_text(encoding="utf-8"))
        self.assertEqual(doc["schema"], "retouchstudio.ai.provenance/1")
        self.assertEqual(doc["contractVersion"], "1")
        self.assertEqual(doc["capabilityId"], "upscale.4x")
        self.assertEqual(doc["jobId"], "job-1")
        self.assertEqual(doc["state"], "succeeded")
        self.assertEqual(doc["model"], {
            "id": "swin2sr-x4", "version": None, "format": "pytorch",
            "provider": "mps",
            "files": [{"path": "pytorch_model.bin", "sha256": "a" * 64}]})
        self.assertEqual(doc["adapter"], {"platform": current_platform(),
                                          "version": __version__})
        self.assertEqual(doc["parameters"], {"scale": 4, "tile": 256, "overlap": 16})
        self.assertIsNone(doc["seed"])
        self.assertIsNone(doc["outsidePixelsIdentical"])
        self.assertEqual(doc["authorizedRect"], {"x": 0.0, "y": 0.0,
                                                 "width": 1.0, "height": 1.0})
        self.assertGreaterEqual(doc["elapsedSeconds"], 0)
        self.assertTrue(doc["createdAt"].endswith("Z"))

    def test_sidecar_digests_are_measured_from_the_published_bytes(self):
        _, _, _, result, error = self._run()
        self.assertIsNone(error)
        doc = json.loads(self._sidecar().read_text(encoding="utf-8"))
        artifact = Path(result["output"])
        source = np.array(Image.open(self.image))
        self.assertEqual(doc["output"]["sha256"],
                         hashlib.sha256(artifact.read_bytes()).hexdigest())
        self.assertEqual(doc["output"], provenance.artifact(artifact))
        self.assertEqual(doc["input"]["sha256"],
                         hashlib.sha256(source.tobytes()).hexdigest())
        self.assertEqual(doc["input"]["width"], 24)
        self.assertEqual(doc["input"]["bitDepth"], 8)
        self.assertEqual(doc["output"]["width"], 96)
        self.assertEqual(doc["output"]["bitDepth"], 8)
        self.assertEqual(doc["output"]["channels"], 3)

    def test_sidecar_binds_the_version_that_was_resolved(self):
        _, _, _, result, error = self._run(version="1.0.0")
        self.assertIsNone(error)
        doc = json.loads(self._sidecar().read_text(encoding="utf-8"))
        self.assertEqual(doc["model"]["version"], "1.0.0")

    def test_sidecar_names_the_cpu_provider_when_mps_is_absent(self):
        engine, _, _, _, error = self._run(mps=False)
        self.assertIsNone(error)
        doc = json.loads(self._sidecar().read_text(encoding="utf-8"))
        self.assertEqual(doc["model"]["provider"], "cpu")
        self.assertEqual(engine.execution_providers(), (["cpu"], None))

    def test_cancel_while_the_weights_load_stops_before_the_first_tile(self):
        cancel = {"asked": False}
        model = _FakeModel(on_load=lambda: cancel.__setitem__("asked", True))

        engine, _, _, result, error = self._run(model=model,
                                                cancel=lambda: cancel["asked"])
        self.assertIsInstance(error, Cancelled)
        self.assertIsNone(result)
        self.assertEqual(model.calls, 0)
        self.assertEqual(list(self.workdir.iterdir()), [])
        self.assertEqual(engine.execution_providers()[0], ["mps"])

    def test_cancel_during_the_write_publishes_nothing(self):
        # The safe points are: before the load, after it, per tile, before the
        # bytes land and after they do. A 32x24 source is one tile, so the fifth
        # check is the one that follows the write.
        asked = {"n": 0}

        def cancel():
            asked["n"] += 1
            return asked["n"] >= 5

        _, _, model, result, error = self._run(cancel=cancel)
        self.assertIsInstance(error, Cancelled)
        self.assertIsNone(result)
        self.assertEqual(model.calls, 1)
        self.assertEqual(list(self.workdir.iterdir()), [])

    def test_a_job_without_a_named_capability_records_its_own(self):
        _, _, _, result, error = self._run(capability=None)
        self.assertIsNone(error)
        doc = json.loads(self._sidecar().read_text(encoding="utf-8"))
        self.assertEqual(doc["capabilityId"], "upscale.4x")

    def test_the_job_result_is_a_pair_a_reader_can_verify(self):
        # What the host adopts is the pair, so the paths it is handed have to
        # describe each other: the sidecar beside the artifact, naming it.
        _, _, _, result, error = self._run()
        self.assertIsNone(error)
        artifact = Path(result["output"])
        self.assertEqual(Path(result["provenance"]),
                         provenance.sidecar_path(artifact))
        doc = provenance.verify(artifact)
        self.assertEqual(doc["jobId"], "job-1")
        self.assertEqual(doc["capabilityId"], "upscale.4x")
        self.assertEqual(doc["output"]["sha256"],
                         provenance.digest_file(artifact))

    def test_artifact_bytes_are_pinned_by_sha256(self):
        # Captured by running the whole-frame quantiser at 689946a before the
        # banded rewrite (327 bytes). The rewrite changes where the temporaries
        # live, not what they compute, so the produced PNG must keep these
        # exact bytes; a pixel-level drift would change the digest.
        _, _, _, result, error = self._run()
        self.assertIsNone(error)
        data = Path(result["output"]).read_bytes()
        self.assertEqual(len(data), 327)
        self.assertEqual(
            hashlib.sha256(data).hexdigest(),
            "8e35b0c06dc7f3cb678b80c3bd3f6656de7246997593c044bf0ae3384c1da1c4")

    def test_a_publication_failure_reports_internal_error_and_publishes_nothing(
            self):
        # The job that cannot prove what it wrote must not report success, and
        # must leave nothing for a host to pick up: not the artifact, not the
        # sidecar, not a temp.
        with mock.patch("retouch_ai_worker.engine.provenance.publish",
                        side_effect=provenance.ProvenanceError(
                            "the pair disagrees")):
            with self.assertRaises(WorkerError) as caught:
                self._run()
        self.assertEqual(caught.exception.code, INTERNAL_ERROR)
        self.assertEqual(list(self.workdir.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
