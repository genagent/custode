"""Nonpaid checks for the native experiment measurement adapter."""
import unittest
from native_composition import native_metadata, objects, observation


class MeasurementTests(unittest.TestCase):
    def test_json_and_sse(self):
        self.assertEqual(objects(b'{"result":{}}'), [{"result": {}}])
        self.assertEqual(objects(b'data: {"result":{}}\n\n'), [{"result": {}}])
        self.assertEqual(objects(b'data: invalid\n'), [])

    def test_does_not_retain_arguments_or_headers(self):
        row = observation({"method": "tools/call", "params": {
            "name": "read_composition", "arguments": {"secret": "hidden"}}},
            200, b'{"result":{"content":[{"text":"hello"}]}}')
        self.assertEqual(row["text_bytes"], 5)
        self.assertNotIn("hidden", str(row))
        self.assertFalse(row["failed"])

    def test_failures_and_partial_are_distinct(self):
        self.assertTrue(observation({"method": "tools/call"}, 403, b'{}')["failed"])
        row = observation({"method": "tools/call"}, 200,
                          b'{"result":{"isError":true,"content":[]}}')
        self.assertTrue(row["failed"])
        row = observation({"method": "tools/call"}, 200,
                          b'{"result":{"content":[{"text":"{\\"status\\":\\"dependency_read_failed\\"}"}]}}')
        self.assertFalse(row["failed"])
        self.assertEqual(row["composition_status"], "dependency_read_failed")

    def test_native_identity_is_from_events(self):
        self.assertEqual(native_metadata("codex", '{"type":"thread.started","thread_id":"native"}')
                         ["session_id"], "native")
        self.assertIsNone(native_metadata("claude", '{"type":"assistant","session_id":"fake"}')
                          ["session_id"])

    def test_unavailable_usage_stays_unknown(self):
        self.assertIsNone(native_metadata("codex", "invalid")["cost_usd"])
        self.assertIsNone(native_metadata("claude", "invalid")["usage"])


if __name__ == "__main__":
    unittest.main()
