"""Publication is a transaction the filesystem cannot provide (W5-0 §3.6).

The rule under test: an artifact a host can adopt always arrives with a
provenance sidecar that names its own bytes. Two renames cannot be made one
atomic act, so this suite injects a failure at every step and asserts which
files exist afterwards — never an artifact alone, never a leftover temp, and
never a record that describes different bytes than the ones that landed.

No Torch, no downloads, no inference: these are filesystem failures, provoked
by patching the three syscalls the writer uses.
"""
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from PIL import Image

from retouch_ai_worker import provenance
from retouch_ai_worker.provenance import ProvenanceError, SIDECAR_SUFFIX


def _record(**overrides):
    """A complete §3.6 record, with only the fields a test needs to be true."""
    record = {
        "schema": provenance.SCHEMA,
        "contractVersion": "1",
        "capabilityId": "upscale.4x",
        "jobId": "job-1",
        "createdAt": "2026-11-17T00:00:00Z",
        "model": {"id": "swin2sr-x4", "version": None, "format": "pytorch",
                  "provider": "mps", "files": []},
        "adapter": {"platform": "macos", "version": "0.0.0"},
        "parameters": {"scale": 4, "tile": 256, "overlap": 16},
        "seed": None,
        "input": {"sha256": "0" * 64, "width": 24, "height": 32,
                  "bitDepth": 8, "channels": 3},
        "output": {"sha256": "0" * 64, "width": 96, "height": 128,
                   "bitDepth": 8, "channels": 3, "colorSpace": "untagged"},
        "authorizedRect": {"x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0},
        "outsidePixelsIdentical": None,
        "elapsedSeconds": 1.5,
        "state": "succeeded",
    }
    record.update(overrides)
    return record


class PublicationTests(unittest.TestCase):
    """The two renames, with a failure attempted in every window between them."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.target = self.tmp / "upscaled.png"

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _staged(self, target: Path | None = None) -> Path:
        """Render a real PNG into a sibling temp, as the job does."""
        artifact = target or self.target
        staged = artifact.with_name(artifact.name + ".tmp")
        Image.fromarray(np.zeros((32, 24, 3), dtype=np.uint8)).save(
            staged, format="PNG")
        return staged

    def _prepared(self) -> tuple[Path, dict]:
        staged = self._staged()
        return staged, _record(output=provenance.artifact(staged))

    def _landed(self) -> list[str]:
        return sorted(entry.name for entry in self.tmp.iterdir())

    def test_a_successful_publish_lands_a_pair_that_verifies(self):
        staged, record = self._prepared()
        sidecar = provenance.publish(staged, self.target, record)
        self.assertEqual(sidecar, provenance.sidecar_path(self.target))
        self.assertEqual(self._landed(),
                         ["upscaled.png", "upscaled.png" + SIDECAR_SUFFIX])
        self.assertFalse(staged.exists(), "the staged temp is consumed")
        self.assertEqual(provenance.verify(self.target)["output"]["sha256"],
                         provenance.digest_file(self.target))

    def test_a_record_that_cannot_be_serialised_creates_nothing(self):
        staged, record = self._prepared()
        record["model"] = {"id": "swin2sr-x4", "note": Path("/tmp/x")}
        with self.assertRaises(TypeError):
            provenance.publish(staged, self.target, record)
        self.assertEqual(self._landed(), [staged.name],
                         "neither the artifact nor a sidecar appeared")

    def test_a_sidecar_that_cannot_be_created_stops_before_the_artifact(self):
        staged, record = self._prepared()
        with mock.patch("retouch_ai_worker.provenance.os.open",
                        side_effect=OSError("no space left on device")):
            with self.assertRaises(OSError):
                provenance.publish(staged, self.target, record)
        self.assertEqual(self._landed(), [staged.name])

    def test_a_sidecar_whose_bytes_fail_leaves_no_partial_file(self):
        staged, record = self._prepared()
        with mock.patch("retouch_ai_worker.provenance.os.write",
                        side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                provenance.publish(staged, self.target, record)
        self.assertEqual(self._landed(), [staged.name],
                         "the half-written sidecar temp was cleaned up")

    def test_a_rename_of_the_sidecar_that_fails_leaves_no_partial_file(self):
        staged, record = self._prepared()
        real_replace = provenance.os.replace

        def refusing(source, destination):
            if Path(destination).name.endswith(SIDECAR_SUFFIX):
                raise OSError("permission denied")
            return real_replace(source, destination)

        with mock.patch("retouch_ai_worker.provenance.os.replace",
                        side_effect=refusing):
            with self.assertRaises(OSError):
                provenance.publish(staged, self.target, record)
        self.assertEqual(self._landed(), [staged.name])

    def test_a_failed_artifact_rename_withdraws_the_sidecar(self):
        staged, record = self._prepared()
        real_replace = provenance.os.replace

        def refusing(source, destination):
            if not Path(destination).name.endswith(SIDECAR_SUFFIX):
                raise OSError("read-only directory")
            return real_replace(source, destination)

        with mock.patch("retouch_ai_worker.provenance.os.replace",
                        side_effect=refusing):
            with self.assertRaises(OSError):
                provenance.publish(staged, self.target, record)
        self.assertEqual(self._landed(), [staged.name],
                         "no orphan sidecar may outlive the commit that failed")

    def test_a_pair_that_disagrees_after_landing_is_removed_whole(self):
        staged, record = self._prepared()
        with mock.patch("retouch_ai_worker.provenance.digest_file",
                        return_value="f" * 64):
            with self.assertRaises(ProvenanceError):
                provenance.publish(staged, self.target, record)
        self.assertEqual(self._landed(), [],
                         "an artifact and a provenance that disagree are "
                         "neither of them evidence")

    def test_cancelling_at_the_publication_boundary_never_tears_the_pair(self):
        # The cancel flag flips while the sidecar is being written. Nothing
        # re-checks cancellation inside `publish`, so the request lands on a
        # commit already under way: the honest outcome is a complete,
        # self-consistent pair that the caller reports. A torn pair is the
        # defect this asserts against.
        staged, record = self._prepared()
        asked = {"cancelled": False}
        real_write = provenance.write

        def writing(artifact_path, payload):
            asked["cancelled"] = True
            return real_write(artifact_path, payload)

        with mock.patch.object(provenance, "write", side_effect=writing):
            sidecar = provenance.publish(staged, self.target, record)
        self.assertTrue(asked["cancelled"])
        self.assertEqual(self._landed(),
                         ["upscaled.png", "upscaled.png" + SIDECAR_SUFFIX])
        self.assertEqual(sidecar, provenance.sidecar_path(self.target))
        provenance.verify(self.target)

    def test_reconcile_clears_an_orphan_sidecar_and_nothing_else(self):
        # Recovery for a process killed between the two renames: the sidecar
        # without an artifact goes; a completed pair stays; other files stay.
        pair = self.tmp / "kept.png"
        Image.fromarray(np.zeros((4, 4, 3), dtype=np.uint8)).save(pair)
        kept_sidecar = provenance.write(pair, _record(
            output=provenance.artifact(pair)))
        orphan = self.tmp / ("vanished.png" + SIDECAR_SUFFIX)
        orphan.write_text("{}", encoding="utf-8")
        unrelated = self.tmp / "notes.txt"
        unrelated.write_text("leave me", encoding="utf-8")

        removed = provenance.reconcile(self.tmp)

        self.assertEqual(removed, [orphan])
        self.assertFalse(orphan.exists())
        self.assertTrue(pair.is_file())
        self.assertTrue(kept_sidecar.is_file())
        self.assertEqual(unrelated.read_text(encoding="utf-8"), "leave me")

    def test_startup_sweep_removes_an_orphan_left_by_a_crashed_job(self):
        # The worker sweeps its own job folders before any job is in flight,
        # which is the only moment that cannot race a live publication.
        from retouch_ai_worker.server import JobManager

        jobs_root = self.tmp / "jobs"
        crashed = jobs_root / "job-crashed"
        crashed.mkdir(parents=True)
        (crashed / "upscaled.png.provenance.json").write_text(
            "{}", encoding="utf-8")
        done = jobs_root / "job-done"
        done.mkdir()
        Image.fromarray(np.zeros((4, 4, 3), dtype=np.uint8)).save(
            done / "upscaled.png")
        provenance.write(done / "upscaled.png", _record(
            output=provenance.artifact(done / "upscaled.png")))

        JobManager(engine=mock.Mock(), jobs_root=jobs_root, allow_roots=())

        self.assertEqual(sorted(p.name for p in crashed.iterdir()), [])
        self.assertEqual(sorted(p.name for p in done.iterdir()),
                         ["upscaled.png", "upscaled.png.provenance.json"])

    def test_verify_refuses_a_missing_unparsable_foreign_or_stale_sidecar(self):
        Image.fromarray(np.zeros((4, 4, 3), dtype=np.uint8)).save(self.target)
        sidecar = provenance.sidecar_path(self.target)

        with self.assertRaises(ProvenanceError):
            provenance.verify(self.target)

        sidecar.write_text("not json", encoding="utf-8")
        with self.assertRaises(ProvenanceError):
            provenance.verify(self.target)

        sidecar.write_text(json.dumps(_record(schema="other/1")),
                           encoding="utf-8")
        with self.assertRaises(ProvenanceError):
            provenance.verify(self.target)

        sidecar.write_text(json.dumps(_record(output={"sha256": "a" * 64})),
                           encoding="utf-8")
        with self.assertRaises(ProvenanceError):
            provenance.verify(self.target)

        # What makes the record honest again is the digest of the real bytes.
        sidecar.write_text(json.dumps(
            _record(output=provenance.artifact(self.target))),
            encoding="utf-8")
        self.assertEqual(provenance.verify(self.target)["state"], "succeeded")


class ArtifactDigestTests(unittest.TestCase):
    """The measured fields a published record is built from."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_staged_bytes_and_the_published_bytes_digest_alike(self):
        path = self.tmp / "upscaled.png.tmp"
        Image.fromarray(np.zeros((32, 24, 3), dtype=np.uint8)).save(
            path, format="PNG")
        before = provenance.artifact(path)
        published = path.with_name("upscaled.png")
        os.replace(path, published)
        self.assertEqual(provenance.artifact(published), before)

    def test_an_icc_profile_is_recorded_as_embedded(self):
        from PIL import ImageCms

        path = self.tmp / "profiled.png"
        image = Image.fromarray(np.zeros((8, 8, 3), dtype=np.uint8))
        profile = ImageCms.createProfile("sRGB")
        image.save(path, icc_profile=ImageCms.ImageCmsProfile(profile).tobytes())
        self.assertEqual(provenance.artifact(path)["colorSpace"],
                         "embedded-profile")


if __name__ == "__main__":
    unittest.main()
