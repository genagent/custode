#!/usr/bin/env python3
"""Bounded, synthetic MCP workflow-decision proof. Only public HTTP responses are evidence."""

import argparse
import json
import os
import subprocess
import sys
import urllib.parse
import uuid

# The shared client lives beside this script; never write bytecode into the checkout.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mcp_conformance import VERSIONS, Client, ProofFailure, fingerprint, require  # noqa: E402

DECISIONS = {"approve": "workflow_launch_approve", "reject": "workflow_launch_reject"}
TOOLS = ["list_attention"] + sorted(DECISIONS.values())
REFUSAL = "workflow launch decision refused: "
# The closed set Custode.MCP.WorkflowDecisionTools emits; anything else is private.
REFUSAL_CODES = {
    "human_identity_required", "no_such_proposal", "expired_proposal", "decision_conflict",
    "retained_run_missing", "unknown_workflow", "outer_transaction_unsupported",
    "admission_failed",
}
TYPES = {"string": str, "number": (int, float), "null": type(None)}


class WorkflowClient(Client):
    """Keeps advertised output schemas, which the shared client does not retain."""

    def __init__(self, url, token, version):
        super().__init__(url, token, version)
        self.outputs = {}

    def rpc(self, method, params=None):
        result = super().rpc(method, params)
        if method == "tools/list":
            for tool in result["tools"]:
                self.outputs[tool["name"]] = tool.get("outputSchema")
        return result

    def tool_result(self, name, args):
        advertised = self.tools[name]
        require(args.keys() <= advertised["properties"].keys(), "advertised_arguments")
        return self.rpc("tools/call", {"name": name, "arguments": args})

    def decide(self, verb, args):
        name = DECISIONS[verb]
        result = self.tool_result(name, args)
        require(result.get("isError") is False, "decision_success:" + verb)
        receipt = result["structuredContent"]
        require(json.loads(result["content"][0]["text"]) == receipt, "receipt_text_parity")
        conforms(receipt, self.outputs[name], "receipt_schema:" + verb)
        require(receipt["proposal_id"] == args["proposal_id"], "receipt_proposal")
        return receipt

    def refused(self, verb, args):
        result = self.tool_result(DECISIONS[verb], args)
        require(result.get("isError") is True and "structuredContent" not in result,
                "tool_refusal_shape")
        text = result["content"][0]["text"]
        require(text.startswith(REFUSAL), "refusal_prefix")
        code = text[len(REFUSAL):]
        require(code in REFUSAL_CODES, "refusal_code")
        return code


def conforms(value, declared, check):
    """The subset of JSON Schema the decision tools declare, checked from discovery."""
    require(isinstance(declared, dict) and declared.get("type") == "object" and
            declared.get("additionalProperties") is False, check)
    properties = declared["properties"]
    require(isinstance(value, dict) and value.keys() == set(declared["required"]) and
            value.keys() <= properties.keys(), check)
    for key, item in value.items():
        rule = properties[key]
        kinds = rule["type"] if isinstance(rule["type"], list) else [rule["type"]]
        require(any(isinstance(item, TYPES[kind]) and type(item) is not bool for kind in kinds),
                check)
        require("enum" not in rule or item in rule["enum"], check)
        if isinstance(item, str):
            require(rule.get("minLength", 0) <= len(item) <= rule.get("maxLength", len(item)),
                    check)


def normalized(declared):
    """Schemas compared across versions, ignoring the order of required keys."""
    if isinstance(declared, dict):
        return {key: sorted(item) if key == "required" else normalized(item)
                for key, item in declared.items()}
    if isinstance(declared, list):
        return [normalized(item) for item in declared]
    return declared


def pending(client, repo):
    """Pending launch proposals for the fixture repository, from list_attention alone."""
    page = client.call("list_attention", {"group": "needs_you"})
    require(all(group["group"] == "needs_you" for group in page["groups"]), "attention_group")
    ids = []
    for group in page["groups"]:
        for signal in group["signals"]:
            if signal["kind"] != "workflow_launch" or not signal["subject"].endswith(" on " + repo):
                continue
            ops = {action["op"]: action["args"] for action in signal["resolving"]}
            proposal = ops["approve_launch"]["proposal"]
            require(ops["reject_launch"] == {"proposal": proposal}, "attention_actions")
            ids.append(proposal)
    require(len(ids) == len(set(ids)) <= 10, "attention_bounded_unique")
    return sorted(ids)


def unknown_id():
    return "wfl-0-" + uuid.uuid4().hex


def connect(args, token):
    schemas, clients = None, {}
    for version in VERSIONS:
        client = WorkflowClient(args.url, token, version)
        client.connect()
        require(set(TOOLS) <= client.tools.keys(), "required_tools")
        current = {name: normalized([client.tools[name], client.outputs.get(name)])
                   for name in TOOLS}
        require(schemas is None or schemas == current, "protocol_schema_parity")
        schemas = current
        clients[version] = client
    return clients[args.protocol]


def journey(args, token, routine_token):
    client = connect(args, token)
    discovered = pending(client, args.repo)
    require(len(discovered) == 3, "attention_discovery")
    approved_id, rejected_id, untouched_id = discovered

    # HTTP authorization is refused before any tool runs.
    for credential in (None, "invalid-synthetic-credential"):
        anonymous = Client(args.url, credential, args.protocol)
        status, _body = anonymous.post("tools/call", {
            "name": DECISIONS["approve"], "arguments": {"proposal_id": untouched_id}})
        require(status == 401, "http_auth_refusal")

    # A routine can see the gate but holds no decision capability.
    caretaker = WorkflowClient(args.url, routine_token, args.protocol)
    caretaker.connect()
    require(not set(DECISIONS.values()) & caretaker.tools.keys(), "routine_capabilities")
    require(untouched_id in pending(caretaker, args.repo), "routine_visibility")
    for name in DECISIONS.values():
        status, denied = caretaker.post("tools/call", {
            "name": name, "arguments": {"proposal_id": untouched_id}})
        require(status == 200 and caretaker.error_code(denied) == -32003 and
                "result" not in denied, "routine_refusal")
    require(pending(client, args.repo) == discovered, "refusals_left_pending")

    # Retain first receipts only as comparison oracles. Retrying uses the
    # original proposal IDs; recovery receives neither receipt.
    approval = {"proposal_id": approved_id}
    first_approval = client.decide("approve", approval)
    approved = client.decide("approve", approval)
    require(approved == first_approval and approved["decision"] == "approved" and
            approved["status"] == "running", "approval_retry")
    rejection = {"proposal_id": rejected_id, "reason": "Synthetic fixture rejection"}
    first_rejection = client.decide("reject", rejection)
    rejected = client.decide("reject", rejection)
    require(rejected == first_rejection == {"proposal_id": rejected_id, "decision": "rejected"},
            "rejection_retry")

    require(pending(client, args.repo) == [untouched_id], "decided_leave_attention")
    # Act on the stale pre-decision view: opposite decisions keep the first one.
    require(client.refused("reject", {"proposal_id": approved_id}) == "decision_conflict" and
            client.refused("approve", {"proposal_id": rejected_id}) == "decision_conflict",
            "opposite_stale_decision")
    for verb in DECISIONS:
        require(client.refused(verb, {"proposal_id": unknown_id()}) == "no_such_proposal",
                "unknown_proposal")

    # An HTTP 200 tool error and a JSON-RPC argument error are both refusals.
    result = client.rpc("tools/call", {"name": DECISIONS["approve"], "arguments": {}})
    require(result.get("isError") is True and "structuredContent" not in result,
            "http200_tool_error")
    status, invalid = client.post("tools/call", {"name": DECISIONS["approve"], "arguments": {
        "proposal_id": untouched_id, "budget_usd": 999}})
    expected_status = 400 if args.protocol == "2026-07-28" else 200
    require(status == expected_status and client.error_code(invalid) == -32602 and
            "result" not in invalid, "jsonrpc_argument_error")
    require(pending(client, args.repo) == [untouched_id], "errors_left_pending")

    # A new interpreter receives only the URL, repository, protocol, operator
    # credential and the proposal IDs this client explicitly retained.
    env = {key: value for key, value in os.environ.items()
           if key != "CUSTODE_CONFORMANCE_ROUTINE_TOKEN"}
    completed = subprocess.run(
        [sys.executable, os.path.abspath(__file__), "--url", args.url, "--repo", args.repo,
         "--protocol", args.protocol, "--recover", "--approved", approved_id,
         "--rejected", rejected_id],
        capture_output=True, text=True, timeout=50, check=False, env=env)
    recovery = json.loads(completed.stdout)
    require(completed.returncode == 0 and recovery.get("ok") is True,
            "fresh_process_recovery:" + str(recovery.get("failed_check")))
    require(recovery.pop("run_fingerprint") == fingerprint([approved["run_id"]]),
            "recovered_same_run")
    require(recovery.pop("pending_fingerprint") == fingerprint([untouched_id]),
            "recovered_same_pending")
    return {"ok": True, "protocol_versions": [args.protocol],
            "discovery_protocol_versions": VERSIONS,
            "protocol_setup": ("initialize_and_initialized" if args.protocol == "2025-11-25"
                               else "stateless_without_initialize"),
            "required_tools": len(TOOLS), "discovered_proposals": len(discovered),
            "checks": {
                "selected_protocol_journey": True, "discovery_schema_parity": True,
                "attention_discovery": True, "receipt_schema": True,
                "approval_retry": True, "rejection_retry": True,
                "opposite_stale_decision": True, "unknown_proposal": True,
                "http_authorization": True, "routine_refusal": True,
                "http200_tool_error": True, "jsonrpc_argument_error": True,
                "fresh_process_recovery": True},
            "recovery": recovery}


def recover(args, token):
    client = connect(args, token)
    still_pending = pending(client, args.repo)
    # Decided proposals are not rediscovered; this client relies on retained IDs.
    require(args.approved not in still_pending and args.rejected not in still_pending and
            len(still_pending) == 1, "retained_ids_resolved")
    approved = client.decide("approve", {"proposal_id": args.approved})
    require(approved["decision"] == "approved" and approved["status"] == "running",
            "retained_approval")
    rejected = client.decide("reject", {"proposal_id": args.rejected,
                                        "reason": "Synthetic later reason"})
    require(rejected == {"proposal_id": args.rejected, "decision": "rejected"},
            "retained_rejection")
    require(client.refused("reject", {"proposal_id": args.approved}) == "decision_conflict" and
            client.refused("approve", {"proposal_id": args.rejected}) == "decision_conflict",
            "retained_conflict")
    require(pending(client, args.repo) == still_pending, "recovery_left_pending")
    return {"ok": True, "reauthenticated": True, "retained_approval": True,
            "retained_rejection": True, "retained_conflict": True,
            "run_fingerprint": fingerprint([approved["run_id"]]),
            "pending_fingerprint": fingerprint(still_pending)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--protocol", required=True, choices=VERSIONS)
    parser.add_argument("--recover", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--approved", help=argparse.SUPPRESS)
    parser.add_argument("--rejected", help=argparse.SUPPRESS)
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.url)
    require(parsed.scheme in ("http", "https") and parsed.hostname and
            not parsed.username and not parsed.password and not parsed.query and
            not parsed.fragment and parsed.path == "/mcp", "explicit_mcp_url")
    require(args.repo.strip() and len(args.repo) <= 100, "synthetic_repo")
    token = os.environ.get("CUSTODE_CONFORMANCE_OPERATOR_TOKEN")
    routine_token = os.environ.get("CUSTODE_CONFORMANCE_ROUTINE_TOKEN")
    require(token and (args.recover or routine_token), "credential_environment")
    if args.recover:
        require(args.approved and args.rejected, "retained_proposals")
        result = recover(args, token)
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
