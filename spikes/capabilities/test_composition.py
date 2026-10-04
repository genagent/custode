import copy
import tempfile
import unittest
from pathlib import Path
from composition import Library


class CompositionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.calls, self.allowed, self.dep = [], True, {"repo_reads": "fixture-v1"}
        self.path = str(Path(self.tmp.name) / "library.sqlite3")
        self.library = self.open()
        self.definition = {"name": "pr_context", "actors": ["tower"], "dependencies": dict(self.dep), "steps": [
            {"operation": op, "arguments": {"repo": {"$arg": "repo"}, "number": {"$arg": "number"}}}
            for op in ("view_pr", "pr_checks", "pr_diff")]}
        self.revision = self.library.publish("human", self.definition)
        self.args = {"repo": "fixture/tower", "number": 42}

    def tearDown(self):
        self.library.db.close()
        self.tmp.cleanup()

    def open(self):
        return Library(self.path, self.authorize, self.dispatch, lambda: self.dep)

    def authorize(self, actor, operation, params):
        if not self.allowed or actor != "tower" or params["repo"] != "fixture/tower":
            raise ValueError("current_scope_denied")

    def dispatch(self, actor, operation, params):
        self.calls.append((actor, operation, params))
        return {"fixture": operation, "head": "abc"}

    def test_one_client_request_preserves_three_underlying_reads_and_caller(self):
        result = self.library.invoke("tower", "pr_context", self.args)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual([call[0] for call in self.calls], ["tower"] * 3)
        self.assertEqual(len(result["trace_ids"]), 3)
        self.assertIn("mixed_revision_possible", result["source_coherence"])
        # Exact measurement: 3 client operations -> 1 composition, still 3 backend
        # reads. No native token, quality or latency savings measured here.

    def test_denied_discovery_and_invocation_do_not_dispatch(self):
        self.assertEqual(self.library.list("other"), [])
        with self.assertRaisesRegex(ValueError, "not_granted"):
            self.library.invoke("other", "pr_context", self.args)
        self.assertEqual(self.calls, [])
        self.allowed = False
        result = self.library.invoke("tower", "pr_context", self.args)
        self.assertEqual(result["error"], "current_scope_denied")
        self.assertEqual(self.calls, [])

    def test_literal_parameter_schema_cannot_evaluate_code_or_smuggle_fields(self):
        for arguments in ({"repo": "fixture/tower; touch /tmp/owned", "number": 1},
                          {"repo": "fixture/tower", "number": True}, dict(self.args, actor="human")):
            with self.assertRaisesRegex(ValueError, "invalid_arguments"):
                self.library.invoke("tower", "pr_context", arguments)
        bad = copy.deepcopy(self.definition)
        bad["steps"][0]["arguments"] = {"$eval": "os.system(...)"}
        with self.assertRaisesRegex(ValueError, "substitution_refused"):
            self.library.publish("human", bad, self.revision)
        bad["steps"][0] = {"operation": "merge_pr", "arguments": {}}
        with self.assertRaisesRegex(ValueError, "read_operation_required"):
            self.library.publish("human", bad, self.revision)
        self.assertEqual(self.calls, [])

    def test_restart_replace_disable_rollback_and_conflict(self):
        self.library.db.close()
        self.library = self.open()
        self.assertEqual(self.library.list("tower"), ["pr_context"])
        new = copy.deepcopy(self.definition)
        new["steps"].pop()
        revision = self.library.publish("human", new, self.revision)
        with self.assertRaisesRegex(ValueError, "activation_conflict"):
            self.library.publish("human", self.definition, self.revision)
        self.assertEqual(len(self.library.invoke("tower", "pr_context", self.args)["results"]), 2)
        self.library.disable("human", "pr_context")
        self.assertEqual(self.library.list("tower"), [])
        with self.assertRaisesRegex(ValueError, "unavailable"):
            self.library.invoke("tower", "pr_context", self.args)
        self.assertEqual(self.library.publish("human", self.definition, revision), self.revision)
        self.assertEqual(len(self.library.invoke("tower", "pr_context", self.args)["results"]), 3)

    def test_current_scope_is_rechecked_before_every_operation(self):
        original = self.library.dispatch
        def dispatch(actor, operation, params):
            result = original(actor, operation, params)
            self.allowed = False
            return result
        self.library.dispatch = dispatch
        result = self.library.invoke("tower", "pr_context", self.args)
        self.assertEqual(len(result["partial"]), 1)
        self.assertEqual(result["error"], "current_scope_denied")
        self.assertEqual(len(self.calls), 1)

    def test_disable_and_dependency_replacement_stop_future_dispatch(self):
        original = self.library.dispatch
        def dispatch(actor, operation, params):
            result = original(actor, operation, params)
            self.library.disable("human", "pr_context")
            return result
        self.library.dispatch = dispatch
        result = self.library.invoke("tower", "pr_context", self.args)
        self.assertEqual(len(result["partial"]), 1)
        self.assertEqual(result["error"], "capability_unavailable")
        self.library.publish("human", self.definition, self.revision)
        self.dep = {"repo_reads": "fixture-v2"}
        with self.assertRaisesRegex(ValueError, "dependency_changed"):
            self.library.invoke("tower", "pr_context", self.args)

    def test_model_authorship_never_grants_publish_or_activation_authority(self):
        for operation in (lambda: self.library.publish("tower", self.definition, self.revision),
                          lambda: self.library.disable("tower", "pr_context")):
            with self.assertRaisesRegex(ValueError, "operator_configuration_required"):
                operation()


if __name__ == "__main__":
    unittest.main()
