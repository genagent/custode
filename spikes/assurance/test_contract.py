import tempfile
import unittest
from pathlib import Path
from contract import Ledger, digest, evaluate


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.policy = {"trusted_recorders": ["host-recorder", "verifier-recorder"], "predicates": [
            {"name": "checks", "classes": ["host_observed", "independently_reproduced"]},
            {"name": "review", "classes": ["independently_reproduced"], "independent": True}]}
        self.case = {"revision": digest({"criteria": "sum exact decimal cents"}), "generation": 1,
                     "policy_revision": digest(self.policy)}
        self.attempt = {"generation": 1, "artifact_revision": digest("source revision"),
                        "producer_actor": "owner", "producer_provider": "claude"}
        self.check = {"id": "checks-1", "predicate": "checks", "trust_class": "host_observed",
                      "issuer": "host-recorder", "case_revision": self.case["revision"],
                      "artifact_revision": self.attempt["artifact_revision"], "outcome": "passed"}
        self.review = dict(self.check, id="review-1", predicate="review", issuer="verifier-recorder",
                           trust_class="independently_reproduced", verifier_actor="reviewer",
                           verifier_provider="codex", verifier_execution="synthetic-fixture-only",
                           pinned_verification=True)

    def evaluate(self, evidence, **changes):
        return evaluate(self.case, dict(self.attempt, **changes), evidence, self.policy)

    def test_clean_and_seeded_defect_contract(self):
        clean = self.evaluate([self.check, self.review])
        self.assertEqual(clean["decision"], "accepted")
        self.assertEqual(clean["effect_authority"], "none")
        failed = dict(self.check, outcome="failed")
        bad = self.evaluate([failed, self.review])
        self.assertEqual(bad["decision"], "rejected")
        self.assertEqual(bad["contradictions"], ["checks"])

    def test_self_report_and_transport_receipt_cannot_satisfy_review(self):
        for trust in ("self_reported", "delivered", "external_attestation"):
            evidence = dict(self.review, trust_class=trust)
            self.assertEqual(self.evaluate([self.check, evidence])["decision"], "escalated")

    def test_fake_recorder_and_missing_independence_do_not_count(self):
        for change in ({"issuer": "model"}, {"verifier_actor": "owner"},
                       {"verifier_provider": "claude"}, {"verifier_execution": None},
                       {"pinned_verification": False}):
            self.assertEqual(self.evaluate([self.check, dict(self.review, **change)])["missing"], ["review"])

    def test_changed_head_case_or_policy_refuses_old_evidence(self):
        self.assertEqual(self.evaluate([self.check, self.review], artifact_revision="new")["missing"], ["checks", "review"])
        self.case["revision"] = "changed"
        self.assertEqual(self.evaluate([self.check, self.review])["missing"], ["checks", "review"])
        self.policy["predicates"].pop()
        self.assertEqual(self.evaluate([self.check])["decision"], "refused")

    def test_disagreement_visible_and_stale_generation_refused(self):
        conflicting = dict(self.review, id="review-2", outcome="failed")
        result = self.evaluate([self.check, self.review, conflicting])
        self.assertEqual(result["contradictions"], ["review"])
        self.assertIn("review", result["satisfied"])
        self.assertEqual(self.evaluate([self.check, self.review], generation=0)["decision"], "refused")

    def test_missing_real_provider_review_escalates(self):
        # A fixture marked independent above tests evaluation logic only. No native
        # review has been executed by this standalone proof.
        self.assertEqual(self.evaluate([self.check])["decision"], "escalated")

    def test_restart_duplicate_reclaim_and_changed_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "facts.sqlite3")
            ledger = Ledger(path)
            ledger.admit("case", "rev", 1)
            saved = ledger.submit("request", "case", "rev", 1, {"commit": "abc"})
            self.assertEqual(ledger.submit("request", "case", "rev", 1, {"commit": "abc"}), saved)
            with self.assertRaisesRegex(ValueError, "idempotency_conflict"):
                ledger.submit("request", "case", "rev", 1, {"commit": "other"})
            ledger.db.close()
            resumed = Ledger(path)
            self.assertEqual(resumed.db.execute("SELECT count(*) FROM submissions").fetchone()[0], 1)
            resumed.reclaim("case")
            with self.assertRaisesRegex(ValueError, "stale_case_or_generation"):
                resumed.submit("late", "case", "rev", 1, {})
            self.assertEqual(resumed.db.execute("SELECT count(*) FROM submissions").fetchone()[0], 1)
            resumed.db.close()


if __name__ == "__main__":
    unittest.main()
