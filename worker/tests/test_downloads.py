import hashlib
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

from retouch_ai_worker.catalog import Catalog, ModelEntry, ModelFile
from retouch_ai_worker.downloads import (ConsentStore, Downloader, manifest,
                                        consent_hash_matches)
from retouch_ai_worker.protocol import (CATALOG_INVALID, CHECKSUM_MISMATCH,
                                        CONSENT_REQUIRED, LICENSE_BLOCKED,
                                        WorkerError)

PAYLOAD = b"retouch-studio-test-payload-" * 4096


class RangeHandler(BaseHTTPRequestHandler):
    requests = []
    paths = []

    def do_GET(self):  # noqa: N802 - http.server naming
        RangeHandler.requests.append(self.headers.get("Range"))
        RangeHandler.paths.append(self.path)
        data = PAYLOAD
        start = 0
        header = self.headers.get("Range")
        if header and header.startswith("bytes="):
            start = int(header.split("=")[1].split("-")[0])
            self.send_response(206)
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class FakeCatalog(Catalog):
    def __init__(self, root, url, sha256, commercial=True):
        super().__init__(root, allow_uncleared=True)
        self.entry = ModelEntry(
            id="fake-model", name="Fake", task="test",
            license_id="Apache-2.0" if commercial else "NOASSERTION",
            commercial_ok=commercial, source="test",
            files=(ModelFile("weights.bin", sha256, len(PAYLOAD), url),),
        )

    def get(self, model_id):
        if model_id != "fake-model":
            raise AssertionError(model_id)
        return self.entry


class TwoFileCatalog(Catalog):
    """One model with two files so a plan can mix installed and missing work."""

    def __init__(self, root, first_url, second_url, sha256):
        super().__init__(root, allow_uncleared=True)
        self.entry = ModelEntry(
            id="fake-model", name="Fake", task="test", license_id="Apache-2.0",
            commercial_ok=True, source="test",
            files=(
                ModelFile("a.bin", sha256, len(PAYLOAD), first_url),
                ModelFile("b.bin", sha256, len(PAYLOAD), second_url),
            ),
        )

    def get(self, model_id):
        if model_id != "fake-model":
            raise AssertionError(model_id)
        return self.entry


class DownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), RangeHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}/weights.bin"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        RangeHandler.requests.clear()
        RangeHandler.paths.clear()
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.sha = hashlib.sha256(PAYLOAD).hexdigest()
        self.catalog = FakeCatalog(self.root, self.url, self.sha)
        self.consent = ConsentStore(self.root / "consent.json")
        self.downloader = Downloader(self.root, self.catalog, self.consent)

    def tearDown(self):
        self.tmp.cleanup()

    def test_consent_is_required(self):
        with self.assertRaises(WorkerError) as caught:
            self.downloader.fetch(["fake-model"])
        self.assertEqual(caught.exception.code, CONSENT_REQUIRED)
        self.assertFalse((self.root / "fake-model" / "weights.bin").exists())
        self.assertEqual(RangeHandler.requests, [])

    def test_consent_hash_binds_the_manifest(self):
        plan = self.downloader.plan(["fake-model"])
        self.consent.grant(plan)
        self.assertTrue(self.consent.allows(plan))
        other = FakeCatalog(self.root, self.url, "0" * 64)
        changed = manifest(["fake-model"], other)
        self.assertFalse(self.consent.allows(changed))

    def test_approval_hash_refuses_a_changed_manifest(self):
        plan = self.downloader.plan(["fake-model"])
        self.assertTrue(consent_hash_matches(plan, plan["manifest_hash"]))
        self.assertTrue(consent_hash_matches(plan, None))
        other = FakeCatalog(self.root, self.url, "0" * 64)
        changed = manifest(["fake-model"], other)
        self.assertFalse(consent_hash_matches(changed, plan["manifest_hash"]))

    def test_fetch_installs_and_verifies(self):
        plan = self.downloader.plan(["fake-model"])
        self.consent.grant(plan)
        result = self.downloader.fetch(["fake-model"])
        target = self.root / "fake-model" / "weights.bin"
        self.assertEqual(target.read_bytes(), PAYLOAD)
        self.assertEqual(result["installed"], ["fake-model/weights.bin"])
        self.assertFalse(any((self.root / ".staging").glob("**/*.part")))

    def test_second_fetch_is_a_no_op(self):
        plan = self.downloader.plan(["fake-model"])
        self.consent.grant(plan)
        self.downloader.fetch(["fake-model"])
        RangeHandler.requests.clear()
        result = self.downloader.fetch(["fake-model"])
        self.assertEqual(result["installed"], [])
        self.assertEqual(RangeHandler.requests, [])

    def test_two_file_plan_counts_installed_bytes_without_refetching(self):
        base = self.url.rsplit("/", 1)[0]
        catalog = TwoFileCatalog(self.root, base + "/a.bin", base + "/b.bin", self.sha)
        downloader = Downloader(self.root, catalog, self.consent)

        installed = self.root / "fake-model" / "a.bin"
        installed.parent.mkdir(parents=True)
        installed.write_bytes(PAYLOAD)

        plan = downloader.plan(["fake-model"])
        self.assertEqual(plan["total_bytes"], 2 * len(PAYLOAD))
        self.consent.grant(plan)

        events = []
        result = downloader.fetch(["fake-model"], progress=events.append)

        self.assertEqual(result["installed"], ["fake-model/b.bin"])
        self.assertEqual((self.root / "fake-model" / "b.bin").read_bytes(), PAYLOAD)
        # The installed file is verified locally and never requested again.
        self.assertEqual(RangeHandler.paths, ["/b.bin"])
        self.assertEqual(RangeHandler.requests, [None])

        self.assertTrue(events)
        self.assertTrue(all(event["total"] == 2 * len(PAYLOAD) for event in events))
        self.assertEqual(events[0]["offset"], len(PAYLOAD))
        completed = [event["offset"] + event["received"] for event in events]
        self.assertEqual(completed, sorted(completed))
        self.assertEqual(completed[-1], 2 * len(PAYLOAD))
        self.assertFalse(any((self.root / ".staging").glob("**/*.part")))

    def test_resume_from_partial_file(self):
        plan = self.downloader.plan(["fake-model"])
        self.consent.grant(plan)
        part = self.root / ".staging" / "fake-model" / "weights.bin.part"
        part.parent.mkdir(parents=True)
        part.write_bytes(PAYLOAD[:1000])
        self.downloader.fetch(["fake-model"])
        self.assertEqual((self.root / "fake-model" / "weights.bin").read_bytes(), PAYLOAD)
        self.assertEqual(RangeHandler.requests, ["bytes=1000-"])

    def test_checksum_mismatch_leaves_nothing_installed(self):
        self.catalog.entry = ModelEntry(
            id="fake-model", name="Fake", task="test", license_id="Apache-2.0",
            commercial_ok=True, source="test",
            files=(ModelFile("weights.bin", "0" * 64, len(PAYLOAD), self.url),),
        )
        plan = self.downloader.plan(["fake-model"])
        self.consent.grant(plan)
        with self.assertRaises(WorkerError) as caught:
            self.downloader.fetch(["fake-model"])
        self.assertEqual(caught.exception.code, CHECKSUM_MISMATCH)
        self.assertFalse((self.root / "fake-model" / "weights.bin").exists())

    def test_plan_refuses_unlicensed_models(self):
        blocked = FakeCatalog(self.root, self.url, self.sha, commercial=False)
        with self.assertRaises(WorkerError) as caught:
            manifest(["fake-model"], blocked)
        self.assertEqual(caught.exception.code, LICENSE_BLOCKED)

    def test_plan_refuses_a_pin_it_could_never_verify(self):
        # Mandate §4 case 6/11 on the transfer side. A pinless entry used to reach
        # the plan with `bytes: None`, quietly contributing zero to the consent
        # total, and the downloaded bytes would then be refused at every load — a
        # multi-gigabyte transfer that can never run. Admission now runs before the
        # consent manifest is even computed, so the user is never asked to approve
        # a download this worker would refuse to load.
        for defect in ("sha256", "bytes"):
            with self.subTest(pin=defect):
                broken = FakeCatalog(self.root, self.url, self.sha)
                broken.entry = ModelEntry(
                    id="fake-model", name="Fake", task="test",
                    license_id="Apache-2.0", commercial_ok=True, source="test",
                    files=(ModelFile("weights.bin",
                                     None if defect == "sha256" else self.sha,
                                     None if defect == "bytes" else len(PAYLOAD),
                                     self.url),))
                with self.assertRaises(WorkerError) as caught:
                    manifest(["fake-model"], broken)
                self.assertEqual(caught.exception.code, CATALOG_INVALID)
                self.assertEqual(caught.exception.data["reason"],
                                 "missing-digest" if defect == "sha256"
                                 else "missing-size")
                self.assertEqual(RangeHandler.requests, [])

    def test_plan_refuses_an_escaping_path_before_offering_it(self):
        # The path is joined onto the install root by the downloader too, so a
        # catalog entry naming `../` would write outside the model store.
        broken = FakeCatalog(self.root, self.url, self.sha)
        broken.entry = ModelEntry(
            id="fake-model", name="Fake", task="test", license_id="Apache-2.0",
            commercial_ok=True, source="test",
            files=(ModelFile("../escaped.bin", self.sha, len(PAYLOAD), self.url),))
        with self.assertRaises(WorkerError) as caught:
            manifest(["fake-model"], broken)
        self.assertEqual(caught.exception.code, CATALOG_INVALID)
        self.assertEqual(caught.exception.data["reason"], "unsafe-path")

    def test_plan_reports_an_aggregate_the_host_can_cross_check(self):
        # Mandate §4 case 11 asked for the aggregate-vs-per-file relationship to
        # be checkable instead of declarative. The worker has no aggregate fields,
        # so it publishes the derived totals next to the consent hash; a host that
        # carries its own (the app's JSON catalog) can now compare rather than
        # trust `total_bytes`.
        plan = manifest(["fake-model"], self.catalog)
        self.assertEqual(plan["aggregate"]["size_bytes"], plan["total_bytes"])
        self.assertEqual(plan["aggregate"]["files"], len(plan["files"]))
        self.assertEqual(sum(item["bytes"] or 0 for item in plan["files"]),
                         plan["aggregate"]["size_bytes"])


if __name__ == "__main__":
    unittest.main()
