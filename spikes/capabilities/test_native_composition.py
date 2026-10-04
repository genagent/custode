"""Nonpaid checks for the native experiment measurement adapter."""
import unittest
from native_composition import native_metadata, objects, observation


class MeasurementTests(unittest.TestCase):
    def test_json_and_sse(self):
        self.assertEqual(objects(b'{"id":1,"result":{}}'), [{"id": 1, "result": {}}])
        self.assertEqual(objects(b'data: {"result":{}}\n\n'), [{"result": {}}])
        self.assertEqual(objects(b'data: invalid\n'), [])

    def test_does_not_retain_arguments_or_headers(self):
        row = observation({"id": 1, "method": "tools/call", "params": {
            "name": "read_composition", "arguments": {"secret": "hidden"}}},
            200, b'{"id":1,"result":{"content":[{"text":"hello"}]}}')
        self.assertEqual(row["text_bytes"], 5)
        self.assertNotIn("hidden", str(row))
        self.assertFalse(row["failed"])

    def test_failures_and_partial_are_distinct(self):
        self.assertTrue(observation({"method": "tools/call"}, 403, b'{}')["failed"])
        row = observation({"id": 1, "method": "tools/call"}, 200,
                          b'{"id":1,"result":{"isError":true,"content":[]}}')
        self.assertTrue(row["failed"])
        row = observation({"id": 1, "method": "tools/call"}, 200,
                          b'{"id":1,"result":{"content":[{"text":"{\\"status\\":\\"dependency_read_failed\\"}"}]}}')
        self.assertFalse(row["failed"])
        self.assertEqual(row["composition_status"], "dependency_read_failed")

    def test_native_identity_is_from_events(self):
        self.assertEqual(native_metadata("codex", '{"type":"thread.started","thread_id":"native"}')
                         ["session_id"], "native")
        self.assertIsNone(native_metadata("claude", '{"type":"assistant","session_id":"fake"}')
                          ["session_id"])

    def test_malformed_and_mismatched_responses_are_not_success(self):
        request = {"id": 1, "method": "tools/call", "params": {"name": "read_composition"}}
        for body in [b"", b"not-json", b"{}", b'{"id":999,"result":{}}', b'{"id":1,"result":null}',
                     b'{"id":1,"result":[]}', b'{"id":1,"result":{}}']:
            row = observation(request, 200, body)
            self.assertTrue(row["failed"])
            self.assertEqual(row["text_bytes"], 0)

    def test_missing_terminal_is_not_native_success(self):
        metadata = native_metadata("codex", '{"type":"thread.started","thread_id":"native"}')
        self.assertTrue(metadata["native_error"])
        self.assertIsNone(metadata["model"])

    def test_unavailable_usage_stays_unknown(self):
        self.assertIsNone(native_metadata("codex", "invalid")["cost_usd"])
        self.assertIsNone(native_metadata("claude", "invalid")["usage"])


if __name__ == "__main__":
    unittest.main()
