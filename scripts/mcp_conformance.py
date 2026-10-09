#!/usr/bin/env python3
"""Bounded, synthetic MCP proof. Only public HTTP responses are evidence."""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

VERSIONS = ["2025-11-25", "2026-07-28"]
TOOLS = ["project_progress", "project_report_digest"] + [
    "work_agreement_" + verb
    for verb in ("create", "read", "checkpoint", "submit", "resolve", "revise")
]
SCHEMAS = ["custode." + name + ".v1" for name in (
    "project_progress", "project_report_digest", "work_agreement_mutation",
    "work_agreement", "work_agreement_list",
)]


class ProofFailure(Exception):
    pass


def require(condition, check):
    if not condition:
        raise ProofFailure(check)


def schema(value, name):
    require(value.get("schema_version") == "custode." + name + ".v1",
            "schema_version:" + name)
    return value


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


class Client:
    def __init__(self, url, token, version):
        self.url, self.token, self.version = url, token, version
        self.count = 0
        self.deadline = time.monotonic() + 45
        self.tools = {}
        # Do not inherit proxies or follow redirects carrying credentials.
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def post(self, method, params=None, notification=False):
        self.count += 1
        require(self.count <= 80 and time.monotonic() < self.deadline, "request_budget")
        params = dict(params or {})
        if self.version == "2026-07-28":
            params["_meta"] = {
                "io.modelcontextprotocol/protocolVersion": self.version,
                "io.modelcontextprotocol/clientCapabilities": {},
            }
        body = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notification:
            body["id"] = self.count
        headers = {"Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream",
                   "MCP-Protocol-Version": self.version}
        if self.version == "2026-07-28":
            headers["Mcp-Method"] = method
            if method == "tools/call":
                headers["Mcp-Name"] = params["name"]
        elif method == "initialize":
            del headers["MCP-Protocol-Version"]
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.url, json.dumps(body).encode(), headers)
        try:
            response = self.http.open(request, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.status
            media_type = response.headers.get_content_type()
            raw = response.read(2_000_001)
            require(len(raw) <= 2_000_000, "response_budget")
        if media_type != "application/json":
            require(status != 200, "json_response_required")
            return status, None
        value = json.loads(raw)
        require(isinstance(value, dict) and value.get("jsonrpc") == "2.0" and
                value.get("id") == self.count,
                "jsonrpc_envelope")
        return status, value

    def rpc(self, method, params=None):
        status, body = self.post(method, params)
        require(status == 200 and "result" in body and "error" not in body,
                "rpc_result:" + self.version + ":" + method + ":http" + str(status) +
                ":code" + str(self.error_code(body)))
        return body["result"]

    @staticmethod
    def error_code(body):
        code = body.get("error", {}).get("code") if isinstance(body, dict) else None
        return code if type(code) is int else None

    def connect(self):
        if self.version == "2025-11-25":
            initialized = self.rpc("initialize", {
                "protocolVersion": self.version, "capabilities": {},
                "clientInfo": {"name": "custode-conformance", "version": "1"}})
            require(initialized["protocolVersion"] == self.version, "negotiated_version")
            require(self.post("notifications/initialized", notification=True)[0] == 202,
                    "initialized_notification")
        # Modern clients deliberately make no initialize request.
        self.discover()

    def discover(self):
        params, seen = {}, set()
        for _ in range(20):
            page = self.rpc("tools/list", params)
            for tool in page["tools"]:
                name = tool["name"]
                require(name not in self.tools, "discovery_duplicate")
                self.tools[name] = tool["inputSchema"]
            cursor = page.get("nextCursor")
            if not cursor:
                break
            require(cursor not in seen, "discovery_cursor")
            seen.add(cursor)
            params = {"cursor": cursor}
        else:
            raise ProofFailure("discovery_budget")

    def call(self, name, args):
        advertised = self.tools[name]
        require(set(advertised.get("required", [])) <= args.keys(), "advertised_required")
        require(args.keys() <= advertised["properties"].keys(), "advertised_arguments")
        result = self.rpc("tools/call", {"name": name, "arguments": args})
        require(result.get("isError") is False, "tool_success:" + name)
        return json.loads(result["content"][0]["text"])

    def mutation(self, verb, args):
        return schema(self.call("work_agreement_" + verb, args), "work_agreement_mutation")

    def read(self, args):
        name = "work_agreement" if "agreement_id" in args else "work_agreement_list"
        return schema(self.call("work_agreement_read", args), name)


def request_id(owner, verb):
    # Owner is uid-generated by the fixture; UUIDs also isolate standalone runs.
    return owner + "-" + verb + "-" + uuid.uuid4().hex


def intent(owner, outcome):
    return {"outcome": outcome, "assignment_id": request_id(owner, "assignment"),
            "criteria": [{"id": "compare", "text": "Compare the synthetic options"}],
            "boundaries": ["Synthetic bookkeeping only"], "inputs": [],
            "request_references": [], "expected_outputs": []}


def fingerprint(ids):
    return hashlib.sha256(json.dumps(sorted(ids)).encode()).hexdigest()


def recover(client, owner):
    """Discover records from owner alone, without mutation receipts or transcript."""
    agreements, cursor, cursors, list_pages = [], None, set(), 0
    for _ in range(4):
        args = {"routine_id": owner, "limit": 1}
        if cursor:
            args["before_id"] = cursor
        page = client.read(args)
        require(page["routine_id"] == owner, "list_owner")
        agreements.extend(page["agreements"])
        list_pages += 1
        if not page["has_more"]:
            require(page["before_id"] is None, "list_terminal_cursor")
            break
        cursor = page["before_id"]
        require(cursor and cursor not in cursors, "list_cursor")
        cursors.add(cursor)
    else:
        raise ProofFailure("list_budget")
    require(len(agreements) == len({a["agreement_id"] for a in agreements}) == 2,
            "list_no_omissions_or_duplicates")
    primary = [a for a in agreements if a["current_revision"] == 2]
    require(len(primary) == 1, "recovered_primary")
    primary = primary[0]
    records, cursor, cursors, history_pages = [], None, set(), 0
    for _ in range(6):
        args = {"agreement_id": primary["agreement_id"], "limit": 1}
        if cursor:
            args["before_sequence"] = cursor
        page = client.read(args)
        require(page["current"] == primary["current"], "history_current_projection")
        records.extend(page["history"]["records"])
        history_pages += 1
        history = page["history"]
        if not history["has_more"]:
            require(history["before_sequence"] is None, "history_terminal_cursor")
            break
        cursor = history["before_sequence"]
        require(cursor and cursor not in cursors, "history_cursor")
        cursors.add(cursor)
    else:
        raise ProofFailure("history_budget")
    require([r["sequence"] for r in records] == [5, 4, 3, 2, 1], "history_sequences")
    require(len({r["record_id"] for r in records}) == 5, "history_unique_records")
    revised, resolved, submitted, checkpoint, created = records
    require([r["kind"] for r in records] ==
            ["revised", "resolution", "submission", "checkpoint", "created"], "history_kinds")
    require([r["revision"] for r in records] == [2, 1, 1, 1, 1], "history_revisions")
    require(resolved["payload"]["submission_id"] == submitted["record_id"] and
            resolved["payload"]["outcome"] == "accepted", "historical_exact_acceptance")
    require(submitted["payload"]["criterion_evidence"][0]["criterion_id"] == "compare" and
            submitted["payload"]["verification_limits"] ==
            "Synthetic evidence only; no provider or external execution.", "recovered_evidence")
    require(checkpoint["recorded_by"]["kind"] == "routine" and
            submitted["recorded_by"]["id"] == owner and
            resolved["recorded_by"]["kind"] == "operator", "attributed_history")
    require(primary["last_sequence"] == 5 and primary["current"]["status"] == "open" and
            primary["current"]["submission"] is None and
            primary["current"]["resolution"] is None and
            primary["current"]["intent_record"]["record_id"] == revised["record_id"] and
            primary["effect_authority"] == "none", "revision_bound_recovery")
    require(created["payload"]["intent"]["assignment_id"] ==
            submitted["payload"]["assignment_id"], "assignment_binding")
    return {"agreements": 2, "history_records": 5, "list_pages": list_pages,
            "history_pages": history_pages, "revision_bound_recovery": True,
            "record_fingerprint": fingerprint([r["record_id"] for r in records]),
            "agreement_fingerprint": fingerprint([a["agreement_id"] for a in agreements])}


def journey(args, token, routine_token):
    schemas, clients = None, {}
    for version in VERSIONS:
        client = Client(args.url, token, version)
        client.connect()
        require(set(TOOLS) <= client.tools.keys(), "required_tools")
        current = {name: client.tools[name] for name in TOOLS}
        require(schemas is None or schemas == current, "protocol_schema_parity")
        schemas = current
        clients[version] = client
    client = clients[args.protocol]
    progress = schema(client.call("project_progress", {"routine_id": args.owner, "limit": 1}),
                      "project_progress")
    require(progress["project"]["routine_id"] == args.owner, "progress_owner")
    digest = schema(client.call("project_report_digest", {"project_limit": 1, "report_limit": 1}),
                    "project_report_digest")
    require([p["owner"] for p in digest["projects"]] == [args.owner], "digest_owner")

    for credential in (None, "invalid-synthetic-credential"):
        require(Client(args.url, credential, args.protocol).post("tools/list")[0] == 401, "http_auth_refusal")
    status, error = client.post("conformance/unknown")
    expected_status = 404 if args.protocol == "2026-07-28" else 200
    require(status == expected_status and client.error_code(error) == -32601 and
            "result" not in error,
            "jsonrpc_method_error")
    result = client.rpc("tools/call", {"name": "work_agreement_read", "arguments": {}})
    require(result.get("isError") is True, "http200_tool_error")

    original_intent = intent(args.owner, "Synthetic comparison")
    create_args = {"request_id": request_id(args.owner, "create"),
                   "routine_id": args.owner, "intent": original_intent}
    first = client.mutation("create", create_args)
    # Deliberately do not use the first receipt to continue. Retry as after a lost reply.
    receipt = client.mutation("create", create_args)
    require(first["duplicate"] is False and receipt == dict(first, duplicate=True), "stable_retry")
    agreement_id = receipt["agreement_id"]
    worker = Client(args.url, routine_token, args.protocol)
    worker.connect()
    require("work_agreement_resolve" not in worker.tools and
            {"work_agreement_checkpoint", "work_agreement_submit"} <= worker.tools.keys(),
            "routine_capabilities")
    checkpoint = worker.mutation("checkpoint", {"request_id": request_id(args.owner, "checkpoint"),
                    "agreement_id": agreement_id, "expected_revision": 1,
                    "summary": "Synthetic options compared", "next_steps": [],
                    "blockers": [], "decisions": []})
    submitted = worker.mutation("submit", {
        "request_id": request_id(args.owner, "submit"), "agreement_id": agreement_id,
        "agreement_revision": 1, "assignment_id": original_intent["assignment_id"],
        "summary": "Synthetic comparison complete", "outputs": [],
        "criterion_evidence": [{"criterion_id": "compare", "references": [
            {"kind": "document", "value": "synthetic-comparison.md"}],
            "note": "Synthetic attributed comparison"}],
        "verification_limits": "Synthetic evidence only; no provider or external execution."})
    resolution = {"request_id": request_id(args.owner, "resolve"), "agreement_id": agreement_id,
                  "expected_revision": 1, "submission_id": submitted["record_id"],
                  "outcome": "accepted", "reason": "Synthetic fixture judgment"}
    status, denied = worker.post("tools/call", {"name": "work_agreement_resolve",
                                              "arguments": resolution})
    require(status == 200 and denied["error"]["code"] == -32003 and "result" not in denied,
            "human_only_resolution")
    resolved = client.mutation("resolve", resolution)
    accepted = client.read({"agreement_id": agreement_id})
    require(accepted["current"]["status"] == "accepted" and
            accepted["current"]["submission"]["record_id"] == submitted["record_id"] and
            accepted["current"]["resolution"]["record_id"] == resolved["record_id"],
            "exact_acceptance")
    revised = client.mutation("revise", {"request_id": request_id(args.owner, "revise"),
                    "agreement_id": agreement_id, "expected_revision": 1,
                    "intent": dict(original_intent, outcome="Synthetic revised comparison")})
    stale = dict(resolution, request_id=request_id(args.owner, "stale"))
    result = client.rpc("tools/call", {"name": "work_agreement_resolve", "arguments": stale})
    require(result.get("isError") is True and
            "revision conflict" in result["content"][0]["text"], "stale_resolution")
    second = client.mutation("create", {"request_id": request_id(args.owner, "second"),
                    "routine_id": args.owner, "intent": intent(args.owner, "Synthetic cursor peer")})
    # A new interpreter knows only the explicit URL, configured owner and credential.
    completed = subprocess.run([sys.executable, os.path.abspath(__file__), "--url", args.url,
                               "--owner", args.owner, "--protocol", args.protocol, "--recover"],
                              capture_output=True, text=True, timeout=50, check=False)
    require(completed.returncode == 0, "fresh_process_recovery")
    recovery = json.loads(completed.stdout)
    require(recovery["revision_bound_recovery"] is True and
            recovery["agreements"] == 2 and recovery["history_records"] == 5,
            "fresh_process_evidence")
    require(recovery.pop("record_fingerprint") == fingerprint([
        r["record_id"] for r in (first, checkpoint, submitted, resolved, revised)]),
        "recovered_same_records")
    require(recovery.pop("agreement_fingerprint") ==
            fingerprint([agreement_id, second["agreement_id"]]), "recovered_same_agreements")
    return {"ok": True, "protocol_versions": [args.protocol],
            "discovery_protocol_versions": VERSIONS,
            "protocol_setup": ("initialize_and_initialized" if args.protocol == "2025-11-25"
                               else "stateless_without_initialize"),
            "schema_versions": SCHEMAS,
            "required_tools": len(TOOLS), "checks": {
                "selected_protocol_journey": True,
                "discovery_schema_parity": True, "configured_owner_reads": True,
                "stable_retry": True, "exact_acceptance": True, "stale_resolution": True,
                "http_authorization": True, "jsonrpc_error": True, "http200_tool_error": True,
                "human_only_resolution": True, "fresh_process_recovery": True},
            "recovery": recovery}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--protocol", required=True, choices=VERSIONS)
    parser.add_argument("--recover", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.url)
    require(parsed.scheme in ("http", "https") and parsed.hostname and
            not parsed.username and not parsed.password and not parsed.query and
            not parsed.fragment and parsed.path == "/mcp", "explicit_mcp_url")
    require(args.owner.strip() and len(args.owner) <= 100, "synthetic_owner")
    token = os.environ.get("CUSTODE_CONFORMANCE_OPERATOR_TOKEN")
    routine_token = os.environ.get("CUSTODE_CONFORMANCE_ROUTINE_TOKEN")
    require(token and (args.recover or routine_token), "credential_environment")
    if args.recover:
        client = Client(args.url, token, args.protocol)
        client.connect()
        result = recover(client, args.owner)
    else:
        result = journey(args, token, routine_token)
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except ProofFailure as error:
        print(json.dumps({"ok": False, "failed_check": str(error)}))
        sys.exit(1)
    except (OSError, ValueError, KeyError, IndexError, AttributeError, TypeError,
            subprocess.TimeoutExpired):
        # Response bodies, identities, URLs and credentials never enter diagnostics.
        print(json.dumps({"ok": False, "failed_check": "transport_or_response"}))
        sys.exit(1)
