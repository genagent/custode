import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from proof import Documents, Refused, serve


class SubjectProof(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "travel"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.root / "README.md").write_text("# Travel\nResearch in research/. Preferences are authored by the human.\n")
        (self.root / "preferences.md").write_text("# Preferences\nQuiet base, rail access.\n")
        self.git("add", "README.md", "preferences.md")
        self.git("commit", "-qm", "fixture initial context")
        self.documents = Documents(self.root)
        self.server, self.thread = serve(self.documents)
        self.url = f"http://127.0.0.1:{self.server.server_port}/mcp"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True)

    def rpc(self, tool, arguments=None, token="fixture-worker-one", error=False):
        payload = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": arguments or {}}}
        request = Request(self.url, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json", "Authorization": "Bearer " + token, "MCP-Protocol-Version": "2026-07-28"})
        with urlopen(request) as response:
            result = json.load(response)["result"]
        if error:
            self.assertTrue(result["isError"])
            return result["content"][0]["text"]
        self.assertFalse(result.get("isError", False))
        return json.loads(result["content"][0]["text"])

    def test_two_fresh_workers_return_to_current_documents_after_cleanup(self):
        worker = Path(self.temporary.name) / "worker-one"
        worker.mkdir()
        preferences = self.rpc("context_read", {"path": "preferences.md"})
        first = self.rpc("context_create", {"path": "research/liguria-november.md", "content": "# Liguria comparison (fixture, not travel advice)\nSource: https://example.invalid/research\nChecked: 2026-10-04\nUncertainty: live availability not checked.\nPurpose: compare quiet rail-connected bases.\n"})
        shutil.rmtree(worker)
        self.assertTrue((self.root / first["path"]).exists())
        (self.root / "preferences.md").write_text("# Preferences\nQuiet base, rail access, no car.\n")
        second_worker = Path(self.temporary.name) / "worker-two"
        second_worker.mkdir()
        paths = self.rpc("context_browse", token="fixture-worker-two")["paths"]
        self.assertIn(first["path"], paths)
        current = self.rpc("context_read", {"path": "preferences.md"}, token="fixture-worker-two")
        self.assertNotEqual(preferences["revision"], current["revision"])
        self.assertIn("no car", current["content"])
        prior = self.rpc("context_search", {"query": "Liguria"}, token="fixture-worker-two")["matches"]
        self.assertEqual(prior[0]["path"], first["path"])
        loaded = self.rpc("context_read", {"path": first["path"]}, token="fixture-worker-two")
        second = self.rpc("context_create", {"path": "research/liguria-follow-up.md", "content": f"# Follow-up fixture\nSource document: {loaded['path']}@{loaded['revision']}\nPreferences: {current['revision']}\nConstraint: no car\n"}, token="fixture-worker-two")
        shutil.rmtree(second_worker)
        self.assertIn(second["path"], self.rpc("context_browse")["paths"])

    def test_stale_proposal_after_uncommitted_human_edit_is_refused(self):
        old = self.rpc("context_read", {"path": "preferences.md"})
        new = "# Preferences\nHuman correction: no car.\n"
        (self.root / "preferences.md").write_text(new)
        error = self.rpc("context_propose", {"path": "preferences.md", "expected_revision": old["revision"], "content": "lost correction"}, error=True)
        self.assertTrue(error.startswith("stale_revision:"))
        self.assertEqual((self.root / "preferences.md").read_text(), new)
        self.assertFalse((self.root / "proposals").exists())

    def test_proposal_diff_is_revision_scoped_and_does_not_replace_authored_source(self):
        old = self.rpc("context_read", {"path": "preferences.md"})
        proposed = self.rpc("context_propose", {"path": old["path"], "expected_revision": old["revision"], "content": old["content"] + "No car.\n"})
        self.assertFalse(proposed["applied"])
        self.assertIn("+No car.", proposed["diff"])
        self.assertEqual(self.rpc("context_read", {"path": old["path"]})["revision"], old["revision"])
        self.assertTrue((self.root / proposed["proposal"]).exists())

    def test_outputs_preserve_unrelated_index_and_worktree_changes_without_auto_commit(self):
        (self.root / "staged.md").write_text("staged by human")
        self.git("add", "staged.md")
        (self.root / "README.md").write_text("uncommitted human map")
        before = (self.git("rev-parse", "HEAD"), self.git("diff", "--cached"), self.git("diff"))
        self.rpc("context_create", {"path": "research/new.md", "content": "fixture result"})
        self.assertEqual(before, (self.git("rev-parse", "HEAD"), self.git("diff", "--cached"), self.git("diff")))

    def test_read_only_identity_cannot_create_or_propose(self):
        self.assertEqual(self.rpc("context_create", {"path": "research/no.md", "content": "no"}, token="fixture-reader", error=True), "read_only")
        self.assertEqual(self.rpc("context_propose", {"path": "preferences.md", "expected_revision": "x", "content": "no"}, token="fixture-reader", error=True), "read_only")
        self.assertIn("Preferences", self.rpc("context_read", {"path": "preferences.md"}, token="fixture-reader")["content"])
        with self.assertRaises(HTTPError) as failure:
            self.rpc("context_browse", token="invented")
        self.assertEqual(failure.exception.code, 401)

    def test_path_scope_and_symlinks_are_refused_in_controlled_fixture(self):
        outside = Path(self.temporary.name) / "secret.md"
        outside.write_text("outside")
        (self.root / "escape.md").symlink_to(outside)
        for path in ("../secret.md", str(outside), ".git/config", "escape.md"):
            self.rpc("context_read", {"path": path}, error=True)
        self.assertEqual(self.rpc("context_create", {"path": "preferences.md", "content": "override"}, error=True), "destination_not_granted")

    def test_create_only_refuses_duplicate_destination_and_bounded_read(self):
        args = {"path": "research/once.md", "content": "first"}
        self.rpc("context_create", args)
        self.rpc("context_create", {**args, "content": "second"}, token="fixture-worker-two", error=True)
        self.assertEqual(self.rpc("context_read", {"path": args["path"]})["content"], "first")
        (self.root / "large.md").write_text("x" * 16385)
        self.assertEqual(self.rpc("context_read", {"path": "large.md"}, error=True), "content_too_large")

    def test_tower_return_flow_keeps_finding_and_decision_separate_from_stale_feedback(self):
        self.rpc("context_create", {"path": "research/rmcp-update.md", "content": "# Synthetic rmcp finding\nChecked: 2026-10-04\nSource: https://example.invalid/rmcp/issue/7\nStatus: needs owner evaluation\n"})
        (self.root / "decisions").mkdir()
        (self.root / "decisions/pr-review.md").write_text("# Synthetic operator decision\nPR: https://example.invalid/tower/pull/42\nDecision: defer pending compatibility evidence\n")
        finding = self.rpc("context_search", {"query": "rmcp"})["matches"][0]
        decision = self.rpc("context_read", {"path": "decisions/pr-review.md"})
        self.assertEqual(finding["path"], "research/rmcp-update.md")
        self.assertIn("defer", decision["content"])
        (self.root / decision["path"]).write_text("# Corrected operator decision\nDecision: keep deferred; new condition\n")
        self.rpc("context_propose", {"path": decision["path"], "expected_revision": decision["revision"], "content": "feedback against old decision"}, error=True)
        current = self.rpc("context_read", {"path": decision["path"]})
        self.assertNotEqual(current["revision"], decision["revision"])

    def test_fixture_delivery_manifest_preserves_only_selected_content_revisions(self):
        self.rpc("context_create", {"path": "research/unselected.md", "content": "not supplied"})
        delivered = self.rpc("context_read", {"path": "preferences.md"})
        manifest = {"state": "fixture_client_received", "documents": [delivered], "provider_observed": False, "tokens": None}
        (self.root / "preferences.md").write_text("new current source")
        self.assertEqual(len(manifest["documents"]), 1)
        self.assertGreater(len(self.rpc("context_browse")["paths"]), 1)
        self.assertIn("Quiet base", manifest["documents"][0]["content"])
        self.assertNotEqual(manifest["documents"][0]["revision"], self.rpc("context_read", {"path": "preferences.md"})["revision"])
        self.assertIsNone(manifest["tokens"])
        self.assertFalse(manifest["provider_observed"])

    def test_history_and_current_diff_are_distinct(self):
        self.assertIn("fixture initial context", self.rpc("context_history", {"path": "preferences.md"})["history"])
        (self.root / "preferences.md").write_text("current uncommitted correction\n")
        self.assertIn("+current uncommitted correction", self.rpc("context_diff", {"path": "preferences.md"})["diff"])


if __name__ == "__main__":
    unittest.main()
