import builtins
import hashlib
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from unittest.mock import patch

import numpy as np
from PIL import Image

from retouch_ai_worker import provenance
from retouch_ai_worker.catalog import Catalog
from retouch_ai_worker.engine import (Cancelled, Context, Engine, _square_box,
                                      composite, mask_policy, region_alpha)
from retouch_ai_worker.protocol import (CHECKSUM_MISMATCH, CONTRACT_VERSION,
                                        INTERNAL_ERROR, INVALID_PARAMS,
                                        WorkerError)

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
        # Behaviour, not a second copy of the filter: a pixel further than the
        # dilation radius (plus the half-pixel the rounded element may reach)
        # from the mask can carry no alpha, whatever the feather does.
        mask = np.zeros((64, 64), dtype=np.uint8)
        mask[28:36, 28:36] = 255
        dilate = 3
        alpha = region_alpha(mask, dilate=dilate, feather=2)
        yy, xx = np.mgrid[0:64, 0:64]
        dy = np.maximum(0, np.maximum(28 - yy, yy - 35)).astype(float)
        dx = np.maximum(0, np.maximum(28 - xx, xx - 35)).astype(float)
        outside = np.hypot(dy, dx) > dilate + 0.5
        self.assertTrue(outside.any())
        self.assertEqual(float(alpha[outside].max()), 0.0)
        self.assertGreater(float(alpha.max()), 0.9)
        self.assertTrue(np.all(alpha >= 0.0) and np.all(alpha <= 1.0))
        for d, f in ((4, 2), (0, 0), (1, 3.5)):
            covered = region_alpha(mask, dilate=d, feather=f)
            self.assertTrue(np.all(covered[28:36, 28:36] > 0.0),
                            f"dilate={d} feather={f}")


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


class EditProvenanceTests(unittest.TestCase):
    """The A1 rule at the publication boundary: named means signed.

    The render is stubbed. These tests are about the pair the app adopts, not
    about what the model drew: which files get a sidecar, what the sidecar is
    allowed to claim, and what a torn or refused publication leaves behind.
    """

    IDENTITY = {"id": "flux2-klein-4b-q4", "version": "1.0.0",
                "format": "safetensors", "provider": "metal",
                "files": [{"path": "model-00001.safetensors", "sha256": "a" * 64}]}

    @staticmethod
    def _ctx(workdir: str, **fields) -> Context:
        cancel = fields.pop("cancel", None)
        return Context(job_id="edit-1", workdir=Path(workdir),
                       cancel=cancel or (lambda: False),
                       progress=lambda event: None,
                       allow_roots=(Path(workdir),), **fields)

    @staticmethod
    def _engine() -> Engine:
        engine = Engine.__new__(Engine)
        engine._ensure_flux = lambda ctx: (None, dict(EditProvenanceTests.IDENTITY))
        engine._generate = lambda model, prompt, reference, width, height, params, ctx: \
            Image.new("RGB", (width, height), (10, 20, 30))
        return engine

    @staticmethod
    def _pixels() -> np.ndarray:
        return np.arange(24 * 32 * 3, dtype=np.uint8).reshape(24, 32, 3)

    def _publish(self, ctx: Context, target: Path, *, capability, pixels=None):
        return Engine.__new__(Engine)._publish_provenanced(
            ctx, target, pixels if pixels is not None else np.zeros((8, 8, 3), np.uint8),
            capability=capability, identity=dict(self.IDENTITY),
            parameters={"engine": "patch"}, seed=7, source=self._pixels(),
            rect={"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
            outside=True, seconds=0.25)

    # --- what the record says ------------------------------------------
    def test_a_labeled_full_frame_signs_both_files_it_hands_over(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = self._pixels()
            result = self._engine()._full_frame(
                source, "golden hour", {"steps": 4},
                self._ctx(tmp, requested_capability="generative.reimagine"), 1.0)

            self.assertEqual(Path(result["provenance"]),
                             provenance.sidecar_path(Path(result["output"])))
            doc = provenance.verify(Path(result["output"]))
            self.assertEqual(doc["capabilityId"], "generative.reimagine")
            self.assertEqual(doc["capabilitySource"], "host-asserted")
            self.assertEqual(doc["jobId"], "edit-1")
            self.assertEqual(doc["contractVersion"], CONTRACT_VERSION)
            self.assertEqual(doc["model"], self.IDENTITY)
            self.assertEqual(doc["state"], "succeeded")
            # The frame was redrawn on purpose, so the honest answer about the
            # pixels outside the region is false, not missing.
            self.assertIs(doc["outsidePixelsIdentical"], False)
            self.assertEqual(doc["seed"], 42)
            self.assertTrue(doc["parameters"]["full_frame"])
            self.assertEqual(doc["input"], provenance.pixels(source))

            # The alpha the host adopts is the worker's own opaque plane, and its
            # record measures the file rather than repeating a claim.
            self.assertEqual(Path(result["alpha_provenance"]),
                             provenance.sidecar_path(Path(result["alpha"])))
            alpha = provenance.verify(Path(result["alpha"]))
            self.assertEqual(alpha["output"]["channels"], 1)
            self.assertEqual(alpha["output"]["bitDepth"], 8)
            self.assertIsNone(alpha["outsidePixelsIdentical"])

    def test_an_unnamed_job_publishes_no_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = self._engine()._full_frame(
                self._pixels(), "golden hour", {}, self._ctx(tmp), 1.0)
            self.assertNotIn("provenance", result)
            self.assertNotIn("alpha_provenance", result)
            self.assertEqual(list(Path(tmp).glob("*" + provenance.SIDECAR_SUFFIX)), [])
            # The files are still there: only the record is withheld, because
            # four capabilities share this kind and nothing here says which ran.
            self.assertTrue(Path(result["output"]).exists())
            self.assertTrue(Path(result["alpha"]).exists())

    def test_only_the_workers_own_verdict_drops_the_label(self):
        with tempfile.TemporaryDirectory() as tmp:
            engine = self._engine()
            self.assertIsNone(engine._recorded_capability(self._ctx(tmp)))
            self.assertEqual(
                engine._recorded_capability(
                    self._ctx(tmp, requested_capability="inpaint.spot")),
                ("inpaint.spot", "host-asserted"))
            self.assertEqual(
                engine._recorded_capability(
                    self._ctx(tmp, capability_id="inpaint.object",
                              requested_capability="inpaint.spot")),
                ("inpaint.object", None))

            result = engine._full_frame(
                self._pixels(), "golden hour", {},
                self._ctx(tmp, capability_id="inpaint.object"), 1.0)
            doc = provenance.verify(Path(result["output"]))
            self.assertEqual(doc["capabilityId"], "inpaint.object")
            self.assertNotIn("capabilitySource", doc)

    def test_a_masked_edit_signs_the_adopted_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.png"
            Image.new("RGB", (64, 64), (200, 100, 50)).save(source)
            plane = np.zeros((64, 64), dtype=np.uint8)
            plane[26:38, 26:38] = 255
            mask = Path(tmp) / "mask.png"
            Image.fromarray(plane).save(mask)

            result = self._engine()._job_patch_edit(
                {"image": {"path": str(source)}, "mask": {"path": str(mask)},
                 "prompt": "remove the lamp", "engine": "patch", "steps": 4,
                 "seed": 7},
                self._ctx(tmp, requested_capability="inpaint.object"))

            # Say which path this proved: the full-frame branch signs `result.png`
            # instead, and a routing threshold change must not quietly move this
            # test onto it.
            self.assertEqual(result["mode"], "patch")
            for artifact, sidecar in (("patch", "patch_provenance"),
                                      ("alpha", "alpha_provenance")):
                self.assertEqual(Path(result[sidecar]),
                                 provenance.sidecar_path(Path(result[artifact])))
                provenance.verify(Path(result[artifact]))
            doc = provenance.verify(Path(result["patch"]))
            self.assertEqual(doc["capabilityId"], "inpaint.object")
            self.assertEqual(doc["capabilitySource"], "host-asserted")
            self.assertEqual(doc["seed"], 7)
            self.assertEqual(doc["parameters"]["prompt"], "remove the lamp")
            self.assertIs(doc["outsidePixelsIdentical"], True)
            rect = doc["authorizedRect"]
            self.assertEqual(sorted(rect), ["height", "width", "x", "y"])
            self.assertTrue(0 <= rect["x"] and rect["x"] + rect["width"] <= 1.0)
            self.assertGreater(rect["width"], 0.0)

    def test_the_inpaint_path_records_no_seed_it_did_not_use(self):
        class Session:
            @staticmethod
            def run(_outputs, feed):
                return [feed["image"].astype(np.uint8)]

        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "source.png"
            Image.new("RGB", (64, 64), (200, 100, 50)).save(source)
            plane = np.zeros((64, 64), dtype=np.uint8)
            plane[26:38, 26:38] = 255
            mask = Path(tmp) / "mask.png"
            Image.fromarray(plane).save(mask)

            engine = self._engine()
            engine._ensure_migan = lambda: (Session(), {
                "id": "migan", "version": None, "format": "onnx",
                "provider": "cpu",
                "files": [{"path": "MI-GAN.onnx", "sha256": "b" * 64}]})
            result = engine._job_patch_edit(
                {"image": {"path": str(source)}, "mask": {"path": str(mask)},
                 "prompt": "continue the sky", "engine": "inpaint", "seed": 11},
                self._ctx(tmp, requested_capability="inpaint.spot"))

            self.assertEqual(result["mode"], "patch")
            self.assertEqual(result["engine"], "inpaint")
            doc = provenance.verify(Path(result["patch"]))
            self.assertEqual(doc["capabilityId"], "inpaint.spot")
            self.assertEqual(doc["capabilitySource"], "host-asserted")
            self.assertEqual(doc["model"]["id"], "migan")
            self.assertEqual(doc["model"]["provider"], "cpu")
            # MI-GAN honours no seed: recording the number the host sent would
            # claim it shaped bytes it never looked at.
            self.assertIsNone(doc["seed"])
            self.assertEqual(doc["parameters"]["engine"], "inpaint")
            provenance.verify(Path(result["alpha"]))

    # --- what a torn publication leaves --------------------------------
    def test_a_second_artifact_is_never_renamed_over(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = self._ctx(tmp, capability_id="inpaint.object")
            target = Path(tmp) / "patch.png"
            target.write_bytes(b"an artifact somebody else published")
            with self.assertRaises(WorkerError) as caught:
                self._publish(ctx, target, capability=("inpaint.object", None))
            self.assertEqual(caught.exception.code, INTERNAL_ERROR)
            self.assertEqual(target.read_bytes(),
                             b"an artifact somebody else published")
            self.assertFalse(provenance.sidecar_path(target).exists())
            self.assertEqual(list(Path(tmp).glob("*.tmp")), [])

    def test_a_cancel_during_publication_leaves_no_pair(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = self._ctx(tmp, capability_id="inpaint.object",
                            cancel=lambda: True)
            target = Path(tmp) / "patch.png"
            with self.assertRaises(Cancelled):
                self._publish(ctx, target, capability=("inpaint.object", None))
            self.assertFalse(target.exists())
            self.assertFalse(provenance.sidecar_path(target).exists())
            self.assertEqual(list(Path(tmp).glob("*.tmp")), [])


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


class LoaderIntegrityTests(unittest.TestCase):
    """No engine path may read model bytes it has not verified.

    Measured on `cd5741b`: three of the four shipped loaders called the
    size-only `require`, so a same-length substitution reached torch, ONNX
    Runtime and MLX unhashed — and only `swin2sr-x4` hashed at all. The source
    check below is deliberately coarse: it names the invariant rather than
    re-implementing the call graph, so adding a fifth loader cannot quietly
    reopen the hole.
    """

    def test_every_catalog_load_in_the_engine_is_verified(self):
        source = (PACKAGE / "engine.py").read_text("utf-8")
        self.assertNotIn("catalog.require(", source,
                         "an engine loader resolved a model without hashing it")
        for model_id in ("swin2sr-x4", "sam2.1-hiera-tiny", "migan",
                         "flux2-klein-4b-q4"):
            with self.subTest(model=model_id):
                self.assertIn(f'require_verified("{model_id}")', source)

    def test_size_only_require_has_no_loader_caller(self):
        # `require` reads no contents, so the only honest callers are reporting
        # paths. If this assertion ever fails, the new caller must be reviewed as
        # a trust-boundary change, not a convenience.
        for name in sorted(path.name for path in PACKAGE.glob("*.py")):
            if name == "catalog.py":
                continue
            source = (PACKAGE / name).read_text("utf-8")
            callers = [line.strip() for line in source.splitlines()
                       if ".require(" in line and "require_verified" not in line]
            with self.subTest(module=name):
                self.assertEqual(callers, [], f"{name} calls size-only require")

    def test_a_tampered_model_never_reaches_a_runtime(self):
        from retouch_ai_worker.catalog import ModelEntry, ModelFile

        # The end-to-end form of the same rule, on the one loader this machine
        # can drive without weights: a fake torch proves whether
        # `from_pretrained` was reached at all. The file is exactly the recorded
        # length, so nothing but the digest can stop it.
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, True)
        inputs = tmp / "inputs"
        inputs.mkdir()
        workdir = tmp / "job"
        workdir.mkdir()
        image = inputs / "photo.png"
        Image.fromarray(np.zeros((16, 12, 3), dtype=np.uint8)).save(image)
        models_root = tmp / "models"
        version = models_root / "swin2sr-x4" / "1.0.0"
        version.mkdir(parents=True)
        (models_root / "swin2sr-x4" / "active.json").write_text(json.dumps({
            "schema": "retouchstudio.model-active/1",
            "modelId": "swin2sr-x4", "version": "1.0.0",
        }), encoding="utf-8")
        entry = ModelEntry(
            id="swin2sr-x4", name="Swin2SR x4", task="upscaling",
            license_id="Apache-2.0", commercial_ok=True, source="local",
            files=(ModelFile("weights.bin",
                             hashlib.sha256(b"trusted").hexdigest(), 7),))
        (version / "weights.bin").write_bytes(b"tampere")
        reached = []

        class _Model:
            def from_pretrained(self, *a, **k):
                reached.append(True)
                raise AssertionError("the loader ran on unverified bytes")

            def to(self, *a, **k):
                return self

            def eval(self):
                return self

        catalog = Catalog(models_root, allow_uncleared=False)
        engine = Engine(catalog, allow_roots=(inputs,))
        ctx = Context(job_id="up-1", workdir=workdir, cancel=lambda: False,
                      progress=lambda fields: None, allow_roots=(inputs,),
                      capability_id="upscale.4x")
        with patch("retouch_ai_worker.catalog.CATALOG", (entry,)):
            with mock.patch.dict(sys.modules, {
                    "torch": SimpleNamespace(
                        backends=SimpleNamespace(
                            mps=SimpleNamespace(is_available=lambda: False))),
                    "transformers": SimpleNamespace(
                        Swin2SRForImageSuperResolution=_Model())}):
                with self.assertRaises(WorkerError) as caught:
                    engine.run("upscale", {"image": {"path": str(image)}}, ctx)
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertEqual(caught.exception.data["reason"], "digest")
        self.assertEqual(caught.exception.data["file"], "weights.bin")
        self.assertFalse(reached, "the runtime was handed bytes it could not verify")
        # A refused load leaves nothing leased, so the owner can still repair it.
        self.assertEqual(catalog._leases, {})

    def test_no_loader_returns_a_path_it_could_not_verify(self):
        # The structural half of "no silent fallback": every loader in the engine
        # resolves its weights through `require_verified`, and none of them keeps
        # a size-only option to fall back to. A runtime import may sit above the
        # load — an unavailable package is answered before 4.6 GB is hashed, which
        # is `sam2`'s documented refusal — but no loader may reach a model path
        # through the size-only accessor.
        source = (PACKAGE / "engine.py").read_text("utf-8")
        loaders = {}
        pattern = re.compile(r"\n    def (_ensure_\w+)\(self.*?(?=\n    def |\nclass |\Z)",
                             re.S)
        for match in pattern.finditer(source):
            loaders[match.group(1)] = match.group(0)

        self.assertEqual(sorted(loaders), ["_ensure_flux", "_ensure_migan",
                                           "_ensure_sam", "_ensure_swin"],
                         "a new loader needs to be covered by this invariant")
        for name, body in loaders.items():
            with self.subTest(loader=name):
                self.assertIn('require_verified("', body,
                              f"{name} resolved weights without hashing them")
                self.assertNotIn(".require(", body.replace("require_verified(", ""))
                # There is no try/except anywhere in a loader that could swallow a
                # verification failure and carry on with the same model id.
                self.assertNotIn("CHECKSUM_MISMATCH", body,
                                 f"{name} catches an integrity refusal")
                self.assertNotIn("CATALOG_INVALID", body,
                                 f"{name} catches a catalog refusal")

        # `sam2`'s honest refusal (no importable runtime, `-32020`) still precedes
        # its verified load: the weights are installable and simply have nothing
        # that reads them, and that answer must not be buried behind a hash.
        sam = loaders["_ensure_sam"]
        self.assertLess(sam.index('"package": "sam2"'),
                        sam.index('require_verified("sam2.1-hiera-tiny")'))


class SamRuntimeTests(unittest.TestCase):
    """A mask job refuses by name when nothing can import `sam2`.

    `sam2` is in neither `requirements.lock` nor the `models` extra, so a
    lock-reproducible runtime has the weights and no package that reads them.
    The answer has to be the typed `-32020` both hosts already map to
    `E_UNSUPPORTED`, and it has to arrive before the catalog leases a model this
    process cannot use.
    """

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.inputs = self.tmp / "inputs"
        self.inputs.mkdir()
        self.image = self.inputs / "photo.png"
        Image.fromarray(np.zeros((24, 32, 3), dtype=np.uint8)).save(self.image)
        self.workdir = self.tmp / "job"
        self.workdir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _context(self):
        return Context(job_id="mask-1", workdir=self.workdir,
                       cancel=lambda: False, progress=lambda fields: None,
                       allow_roots=(self.inputs,), capability_id="mask.click")

    def test_an_unimportable_package_refuses_the_job_before_the_model(self):
        # `sys.modules[name] = None` makes `import name` raise ImportError
        # without touching the machine's real environment, so this proves the
        # same refusal on a Mac that does have sam2 installed.
        catalog = Catalog(self.tmp / "models", allow_uncleared=False)
        engine = Engine(catalog, allow_roots=(self.inputs,))
        params = {"image": {"path": str(self.image)}, "box": [4, 4, 20, 20]}
        with mock.patch.object(Catalog, "require") as require:
            with mock.patch.dict(sys.modules, {"sam2": None}):
                with self.assertRaises(WorkerError) as caught:
                    engine.run("mask", params, self._context())
        self.assertEqual(caught.exception.code, -32020)
        self.assertEqual(caught.exception.data["package"], "sam2")
        self.assertEqual(caught.exception.data["capabilityId"], "mask.click")
        # The host routes on `state`; without it a mask refusal fell through
        # to the "not in this build" sentence even though the state is known.
        self.assertEqual(caught.exception.data["state"], "blocked")
        self.assertIn("cannot import sam2", caught.exception.data["reason"])
        self.assertIn("nothing to run on", str(caught.exception))
        self.assertFalse(require.called,
                         "the refusal ran after a lease was taken")
        self.assertEqual(list(self.workdir.iterdir()), [],
                         "a refused job left bytes in its workdir")


if __name__ == "__main__":
    unittest.main()
