import unittest
from unittest.mock import Mock
import native_catalog_probe as probe


class NonpaidBoundaryTest(unittest.TestCase):
    def test_remote_or_ambiguous_endpoints_are_refused_before_launch(self):
        for url in ["http://127.0.0.1:8000@remote.invalid/mcp", "https://127.0.0.1:8000/mcp",
                    "http://127.0.0.1:8000/mcp?token=secret", "http://localhost:8000/mcp",
                    "http://127.0.0.1:8000/other", "http://127.0.0.1/mcp"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                probe.main(url)

    def test_inference_and_effect_requests_cannot_enter_the_native_rpc_writer(self):
        app = probe.AppServer.__new__(probe.AppServer)
        app.send = Mock()
        for method in ["thread/start", "turn/start", "mcpServer/tool/call", "config/write"]:
            with self.subTest(method=method), self.assertRaises(ValueError):
                app.request(method, {}, 1)
        app.send.assert_not_called()

    def test_missing_or_failed_status_never_becomes_discovery_success(self):
        self.assertEqual(probe.inventory({"error": {"code": -32601}}),
                         {"state": "unavailable", "error_code": -32601})
        self.assertEqual(probe.inventory({"result": {"data": []}})["state"], "unavailable")


if __name__ == "__main__":
    unittest.main()
