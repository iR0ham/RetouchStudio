import json
import os
import tempfile
import unittest
from pathlib import Path

from retouch_ai_worker.registry import RegistryWriter, process_identity

GENERATION = "11111111-1111-4111-8111-111111111111"
NONCE = "22222222-2222-4222-8222-222222222222"


class RegistryTests(unittest.TestCase):
    def test_process_identity_matches_the_current_process(self):
        identity = process_identity()
        self.assertIsNotNone(identity)
        self.assertEqual(identity["pid"], os.getpid())
        self.assertGreater(identity["start_seconds"], 0)
        self.assertTrue(identity["executable"])

    def test_starting_then_ready_publishes_a_private_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "helper-registry.json"
            writer = RegistryWriter(path, GENERATION, NONCE,
                                    str(root / "worker.sock"))
            writer.starting()
            starting = json.loads(path.read_text())
            self.assertEqual(starting["state"], "starting")
            self.assertEqual(starting["generation"], GENERATION)
            self.assertEqual(starting["launch_nonce"], NONCE)
            self.assertEqual(starting["schema"], 2)
            self.assertEqual(starting["protocol_version"], 2)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            writer.ready()
            ready = json.loads(path.read_text())
            self.assertEqual(ready["state"], "ready")
            self.assertEqual(ready["revision"], starting["revision"] + 1)
            self.assertEqual(ready["helper"]["pid"], os.getpid())
            self.assertEqual(set(ready), {
                "schema", "protocol_version", "generation", "launch_nonce",
                "revision", "state", "parent", "helper", "socket", "created_at",
                "updated_at", "shutdown", "clients", "last_error"})

    def test_another_launch_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "helper-registry.json"
            writer = RegistryWriter(path, GENERATION, NONCE,
                                    str(root / "worker.sock"))
            writer.starting()
            other = RegistryWriter(path, "33333333-3333-4333-8333-333333333333",
                                   NONCE, str(root / "worker.sock"))
            with self.assertRaises(RuntimeError):
                other.ready()
            self.assertEqual(json.loads(path.read_text())["generation"], GENERATION)


if __name__ == "__main__":
    unittest.main()
