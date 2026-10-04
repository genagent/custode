"""Standalone assurance contract proof. Not a production authority or provider verifier."""
import hashlib
import json
import sqlite3


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def evaluate(case, attempt, evidence, policy):
    missing, contradictions, satisfied = [], [], []
    if attempt["generation"] != case["generation"]:
        return {"decision": "refused", "missing": ["current_generation"], "contradictions": [], "satisfied": []}
    if case["policy_revision"] != digest(policy):
        return {"decision": "refused", "missing": ["pinned_policy"], "contradictions": [], "satisfied": []}
    for predicate in policy["predicates"]:
        matching = [e for e in evidence if e["predicate"] == predicate["name"]
                    and e["case_revision"] == case["revision"]
                    and e["artifact_revision"] == attempt["artifact_revision"]
                    and e["trust_class"] in predicate["classes"]
                    and e["issuer"] in policy["trusted_recorders"]]
        if predicate.get("independent"):
            matching = [e for e in matching if e["verifier_actor"] != attempt["producer_actor"]
                        and e["verifier_provider"] != attempt["producer_provider"]
                        and e.get("verifier_execution") and e.get("pinned_verification")]
        if any(e["outcome"] == "failed" for e in matching):
            contradictions.append(predicate["name"])
        if any(e["outcome"] == "passed" for e in matching):
            satisfied.append(predicate["name"])
        if not matching or all(e["outcome"] not in ("passed", "failed") for e in matching):
            missing.append(predicate["name"])
    decision = "rejected" if contradictions else "escalated" if missing else "accepted"
    return {"decision": decision, "missing": missing, "contradictions": contradictions, "satisfied": satisfied,
            "case_revision": case["revision"], "artifact_revision": attempt["artifact_revision"],
            "policy_revision": case["policy_revision"], "evidence_ids": [e["id"] for e in evidence],
            "effect_authority": "none"}


class Ledger:
    """SQLite transaction proof, independent of Custode's frozen kernel."""
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS cases (id TEXT PRIMARY KEY, revision TEXT, generation INTEGER);
        CREATE TABLE IF NOT EXISTS submissions (request_id TEXT PRIMARY KEY, case_id TEXT,
          generation INTEGER, payload TEXT);
        """)

    def admit(self, identity, revision, generation):
        with self.db:
            self.db.execute("INSERT INTO cases VALUES (?, ?, ?)", (identity, revision, generation))

    def reclaim(self, identity):
        with self.db:
            self.db.execute("UPDATE cases SET generation=generation+1 WHERE id=?", (identity,))

    def submit(self, request_id, case_id, revision, generation, payload):
        encoded = json.dumps(payload, sort_keys=True)
        self.db.execute("BEGIN IMMEDIATE")
        try:
            current = self.db.execute("SELECT revision, generation FROM cases WHERE id=?", (case_id,)).fetchone()
            if current != (revision, generation):
                raise ValueError("stale_case_or_generation")
            previous = self.db.execute("SELECT case_id, generation, payload FROM submissions WHERE request_id=?", (request_id,)).fetchone()
            if previous and previous != (case_id, generation, encoded):
                raise ValueError("idempotency_conflict")
            self.db.execute("INSERT OR IGNORE INTO submissions VALUES (?, ?, ?, ?)", (request_id, case_id, generation, encoded))
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        return encoded
