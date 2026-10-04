"""Standalone data-composition proof; no production MCP activation or code evaluator."""
import hashlib
import json
import re
import sqlite3

READS = {"view_pr", "pr_checks", "pr_diff"}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def substitute(value, arguments):
    if isinstance(value, dict):
        if set(value) == {"$arg"}:
            return arguments[value["$arg"]]
        if any(key.startswith("$") for key in value):
            raise ValueError("executable_or_unknown_substitution_refused")
        return {key: substitute(child, arguments) for key, child in value.items()}
    if isinstance(value, list):
        return [substitute(child, arguments) for child in value]
    return value


class Library:
    def __init__(self, path, authorize, dispatch, dependencies):
        self.authorize, self.dispatch, self.dependencies = authorize, dispatch, dependencies
        self.db = sqlite3.connect(path)
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS definitions (name TEXT, revision TEXT, definition TEXT,
          PRIMARY KEY(name,revision));
        CREATE TABLE IF NOT EXISTS activation (name TEXT PRIMARY KEY, revision TEXT, enabled INTEGER);
        CREATE TABLE IF NOT EXISTS traces (id INTEGER PRIMARY KEY, capability_revision TEXT,
          actor TEXT, operation TEXT, input_digest TEXT, outcome TEXT);
        """)

    def publish(self, trusted_actor, definition, expected=None):
        if trusted_actor != "human":
            raise ValueError("operator_configuration_required")
        if set(definition) != {"name", "actors", "steps", "dependencies"}:
            raise ValueError("invalid_definition")
        if not 1 <= len(definition["steps"]) <= 4:
            raise ValueError("step_limit")
        for step in definition["steps"]:
            if set(step) != {"operation", "arguments"} or step["operation"] not in READS:
                raise ValueError("compiled_read_operation_required")
            substitute(step["arguments"], {"repo": "fixture/repo", "number": 1})
        encoded, revision = json.dumps(definition, sort_keys=True), digest(definition)
        self.db.execute("BEGIN IMMEDIATE")
        try:
            current = self.db.execute("SELECT revision FROM activation WHERE name=?", (definition["name"],)).fetchone()
            if (current[0] if current else None) != expected:
                raise ValueError("activation_conflict")
            self.db.execute("INSERT OR IGNORE INTO definitions VALUES (?, ?, ?)", (definition["name"], revision, encoded))
            self.db.execute("INSERT OR REPLACE INTO activation VALUES (?, ?, 1)", (definition["name"], revision))
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        return revision

    def disable(self, trusted_actor, name):
        if trusted_actor != "human":
            raise ValueError("operator_configuration_required")
        with self.db:
            self.db.execute("UPDATE activation SET enabled=0 WHERE name=?", (name,))

    def active(self, name):
        row = self.db.execute("SELECT d.definition, a.revision FROM activation a JOIN definitions d ON d.name=a.name AND d.revision=a.revision WHERE a.name=? AND a.enabled=1", (name,)).fetchone()
        if not row:
            raise ValueError("capability_unavailable")
        return json.loads(row[0]), row[1]

    def list(self, actor):
        names = [row[0] for row in self.db.execute("SELECT name FROM activation WHERE enabled=1 ORDER BY name")]
        return [name for name in names if actor in self.active(name)[0]["actors"]]

    def invoke(self, actor, name, arguments):
        definition, revision = self.active(name)
        if actor not in definition["actors"]:
            raise ValueError("capability_not_granted")
        if set(arguments) != {"repo", "number"} or not isinstance(arguments["repo"], str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments["repo"]):
            raise ValueError("invalid_arguments")
        if type(arguments["number"]) is not int or not 1 <= arguments["number"] <= 100000:
            raise ValueError("invalid_arguments")
        if definition["dependencies"] != self.dependencies():
            raise ValueError("dependency_changed")
        results, trace = [], []
        for step in definition["steps"]:
            try:
                if self.active(name)[1] != revision:
                    raise ValueError("activation_changed")
                if definition["dependencies"] != self.dependencies():
                    raise ValueError("dependency_changed")
                params = substitute(step["arguments"], arguments)
                self.authorize(actor, step["operation"], params)
                result = self.dispatch(actor, step["operation"], params)
                if len(json.dumps(result).encode()) > 65536:
                    raise ValueError("result_limit")
                results.append(result)
                outcome = "returned"
            except ValueError as error:
                outcome = str(error)
            with self.db:
                cursor = self.db.execute("INSERT INTO traces(capability_revision,actor,operation,input_digest,outcome) VALUES (?,?,?,?,?)",
                                         (revision, actor, step["operation"], digest(arguments), outcome))
                trace.append(cursor.lastrowid)
            if outcome != "returned":
                return {"revision": revision, "partial": results, "error": outcome, "trace_ids": trace}
        return {"revision": revision, "results": results, "trace_ids": trace,
                "source_coherence": "mixed_revision_possible_diff_has_no_head_binding"}
