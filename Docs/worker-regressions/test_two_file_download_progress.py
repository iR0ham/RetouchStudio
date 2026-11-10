"""Standalone copy of the P0-06 two-file download-progress regression.

The Python worker lives in a separate checkout (``~/RetouchStudio-Phase0/worker``)
that is not a Git repository. The regression is maintained in that checkout's
``tests/test_downloads.py``; this copy keeps it in the main repository so a
fresh clone still has the test.

This module is not part of the Swift suite (``Tests/run.sh``) and no build or
CI step runs it. To execute it against the external worker source:

    cd ~/RetouchStudio-Phase0
    PYTHONPATH=worker .venv/bin/python \
        /path/to/RetouchStudio/Docs/worker-regressions/test_two_file_download_progress.py -v

Alternatively, copy it into the worker's ``tests/`` directory and run unittest
discovery there. It imports only the public worker modules and defines its own
HTTP fixture, so no worker implementation is duplicated here.
"""
import hashlib
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory

from retouch_ai_worker.catalog import Catalog, ModelEntry, ModelFile
from retouch_ai_worker.downloads import ConsentStore, Downloader

PAYLOAD = b"retouch-studio-test-payload-" * 4096


class _RangeHandler(BaseHTTPRequestHandler):
    requests = []
    paths = []

    def do_GET(self):  # noqa: N802 - http.server naming
        _RangeHandler.requests.append(self.headers.get("Range"))
        _RangeHandler.paths.append(self.path)
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


class _TwoFileCatalog(Catalog):
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


class TwoFileDownloadProgressRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _RangeHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}/weights.bin"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        _RangeHandler.requests.clear()
        _RangeHandler.paths.clear()
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.sha = hashlib.sha256(PAYLOAD).hexdigest()
        self.consent = ConsentStore(self.root / "consent.json")

    def tearDown(self):
        self.tmp.cleanup()

    def test_two_file_plan_counts_installed_bytes_without_refetching(self):
        base = self.url.rsplit("/", 1)[0]
        catalog = _TwoFileCatalog(self.root, base + "/a.bin", base + "/b.bin", self.sha)
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
        self.assertEqual(_RangeHandler.paths, ["/b.bin"])
        self.assertEqual(_RangeHandler.requests, [None])

        self.assertTrue(events)
        self.assertTrue(all(event["total"] == 2 * len(PAYLOAD) for event in events))
        self.assertEqual(events[0]["offset"], len(PAYLOAD))
        completed = [event["offset"] + event["received"] for event in events]
        self.assertEqual(completed, sorted(completed))
        self.assertEqual(completed[-1], 2 * len(PAYLOAD))
        self.assertFalse(any((self.root / ".staging").glob("**/*.part")))


if __name__ == "__main__":
    unittest.main()
