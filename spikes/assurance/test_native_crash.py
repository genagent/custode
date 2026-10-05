"""Adversarial controller guards. Never launches a CLI or application."""
import json
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch
import native_crash as proof


class ControllerTest(unittest.TestCase):
    def test_initialization_is_not_success_and_conflicts_refuse(self):
        raw = b'[]\n{"type":"thread.started","thread_id":"private"}\n'
        self.assertEqual(proof.initialized("codex", raw)["session_id"], "private")
        self.assertIsNone(proof.initialized("codex", b'{}\n'))
        with self.assertRaises(ValueError):
            proof.initialized("codex", raw + b'{"type":"turn.completed"}\n')
        with self.assertRaises(ValueError):
            proof.initialized("codex", raw + b'{"type":"thread.started","thread_id":"other"}\n')
        with self.assertRaises(ValueError):
            proof.initialized("claude", b'{"type":"result"}\n')

    def test_signals_require_observation_and_refuse_pid_reuse(self):
        identity = {"pid": 999999, "started": "first", "image": "owned", "parent": 1}
        with patch.object(proof.os, "kill") as kill:
            with self.assertRaises(ValueError):
                proof.signal_owned(identity, signal.SIGKILL, {})
            with patch.object(proof, "snapshot", return_value={999999: identity | {"started": "second"}}):
                self.assertFalse(proof.signal_owned(identity, signal.SIGKILL, {999999: identity}))
            kill.assert_not_called()

    def test_capture_limit_is_enforced_during_read(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "raw"
            path.write_bytes(b"x" * (proof.LIMIT + 1))
            with self.assertRaises(ValueError):
                proof.read_bounded(path)
            path.write_bytes(b"x" * proof.LIMIT)
            self.assertEqual(len(proof.read_bounded(path)), proof.LIMIT)

    def test_public_controls_refuse_unexpected_or_non_boolean_fields(self):
        controls = {key: True for key in proof.CONTROL_KEYS}
        self.assertEqual(proof.public_controls(controls), controls)
        for bad in [controls | {"session_id": "secret"}, controls | {proof.CONTROL_KEYS[0]: "secret"}]:
            with self.assertRaises(ValueError):
                proof.public_controls(bad)

    def test_public_projection_drops_raw_native_and_account_metadata(self):
        case = {key: "hash" for key in ["stdout_sha256", "stderr_sha256", "native_identity_sha256", "native_session_sha256"]}
        case.update(provider="claude", failure="native_worker_killed", initialization_observed=True,
                    native_status="incomplete", observed_processes_gone=True, all_descendants_attestation="missing",
                    private_path="secret", session_id="secret", usage="secret",
                    recovery={"native_record": {"secret": "secret"}, "controls": {key: True for key in proof.CONTROL_KEYS},
                              "decision": {"status": "escalated"}})
        private = {"cases": [case], "synthetic": True, "source_revision": "hash", "source_sha256": {},
                   "status": "passed", "model_launch_requests": 2}
        self.assertNotIn("secret", json.dumps(proof.projection(private)))


if __name__ == "__main__":
    unittest.main()
