import json
import unittest

from retouch_ai_worker import PROTOCOL_VERSION_STRING, protocol
from retouch_ai_worker.protocol import WorkerError, decode, encode, parse_request


class ProtocolTests(unittest.TestCase):
    def test_roundtrip(self):
        message = {"jsonrpc": "2.0", "id": 7, "result": {"عنوان": "آزمون"}}
        self.assertEqual(decode(encode(message)), message)

    def test_newline_is_frame_boundary(self):
        frame = encode({"a": "line\nbreak"})
        self.assertEqual(frame.count(b"\n"), 1)
        self.assertTrue(frame.endswith(b"\n"))

    def test_invalid_json(self):
        with self.assertRaises(WorkerError) as caught:
            decode(b"{not json}\n")
        self.assertEqual(caught.exception.code, protocol.PARSE_ERROR)

    def test_frame_limit(self):
        with self.assertRaises(WorkerError):
            decode(b"x" * (protocol.MAX_FRAME_BYTES + 1))
        self.assertEqual(protocol.MAX_FRAME_BYTES, 1024 * 1024)

    def test_requires_jsonrpc_2(self):
        with self.assertRaises(WorkerError):
            parse_request({"jsonrpc": "1.0", "method": "ping"})

    def test_notification_has_no_id(self):
        request = parse_request({"jsonrpc": "2.0", "method": "ping"})
        self.assertTrue(request.is_notification)
        self.assertIsNone(request.id)

    def test_params_must_be_object(self):
        with self.assertRaises(WorkerError):
            parse_request({"jsonrpc": "2.0", "id": 1, "method": "x", "params": [1]})

    def test_error_response_shape(self):
        response = protocol.error_response(3, WorkerError(protocol.BUSY, "busy", {"job": "a"}))
        self.assertEqual(response["error"]["code"], protocol.BUSY)
        self.assertEqual(response["error"]["data"], {"job": "a"})

    def test_worker_errors_are_json_serialisable(self):
        json.dumps(protocol.error_response(1, WorkerError(protocol.MODEL_MISSING, "gone")))

    def test_responses_carry_contract_version(self):
        result = protocol.result_response(1, {"ok": True})
        self.assertEqual(result["contractVersion"], protocol.CONTRACT_VERSION)
        error = protocol.error_response(1, WorkerError(protocol.BUSY, "busy"))
        self.assertEqual(error["contractVersion"], protocol.CONTRACT_VERSION)
        self.assertEqual(protocol.notification("x", {})["contractVersion"],
                         protocol.CONTRACT_VERSION)

    def test_unsupported_contract_version_is_refused(self):
        with self.assertRaises(WorkerError) as caught:
            parse_request({"jsonrpc": "2.0", "id": 1, "method": "ping",
                           "contractVersion": "99"})
        self.assertEqual(caught.exception.code, protocol.INVALID_REQUEST)

    def test_protocol_version_is_two(self):
        self.assertEqual(protocol.PROTOCOL_VERSION, 2)
        self.assertEqual(PROTOCOL_VERSION_STRING, "2")


if __name__ == "__main__":
    unittest.main()
