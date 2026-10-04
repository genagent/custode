"""Opt-in actual CLI experiment against a scoped Custode HTTP test endpoint.

The proxy narrows discovery for this experiment, records calls/results (never
headers or argument values), and forwards unchanged invocations to Custode.
It is a measurement adapter, not a production authorization implementation.
"""
import http.client
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

TOOLS = ["repo_view_pr", "repo_pr_checks", "repo_pr_diff", "read_composition"]


def objects(body):
    try:
        value = json.loads(body)
        return value if isinstance(value, list) else [value]
    except (ValueError, UnicodeDecodeError):
        values = []
        for line in body.splitlines():
            if line.startswith(b"data: "):
                try:
                    values.append(json.loads(line[6:]))
                except ValueError:
                    pass
        return values


def observation(request, status, body):
    method = request.get("method")
    row = {"method": method, "http_status": status}
    responses = [v for v in objects(body) if isinstance(v, dict) and v.get("id") == request.get("id")]
    valid = len(responses) == 1 and ("result" in responses[0]) != ("error" in responses[0])
    if method == "initialize":
        row["protocol"] = responses[0].get("result", {}).get("protocolVersion") if valid else None
    if method == "tools/call":
        row["tool"] = request.get("params", {}).get("name")
        results = [v["result"] for v in responses if isinstance(v.get("result"), dict)]
        row["failed"] = status >= 400 or not valid or any("error" in v for v in responses)
        row["failed"] = row["failed"] or any(r.get("isError", False) for r in results)
        row["text_bytes"] = sum(len(c.get("text", "").encode())
                                for r in results for c in r.get("content", []))
        row["composition_status"] = None
        row["observed_heads"] = []
        for r in results:
            for c in r.get("content", []):
                try:
                    data = json.loads(c.get("text", ""))
                    if isinstance(data, dict):
                        row["composition_status"] = data.get("status")
                        row["trace_id"] = data.get("trace_id")
                        for head in ["fixture-old-head", "fixture-new-head"]:
                            if head in c.get("text", ""):
                                row["observed_heads"].append(head)
                except ValueError:
                    pass
    return row


def native_metadata(provider, stdout):
    events = []
    for line in stdout.splitlines():
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                events.append(value)
        except ValueError:
            pass
    if provider == "claude":
        init = next((e for e in events if e.get("type") == "system" and
                     e.get("subtype") == "init"), {})
        final = next((e for e in reversed(events) if e.get("type") == "result"), {})
        return {"session_id": init.get("session_id"), "model": init.get("model"),
                "usage": final.get("usage"), "cost_usd": final.get("total_cost_usd"),
                "terminal_event": final.get("subtype"), "native_error": final.get("is_error"),
                "event_count": len(events), "interpretation": interpretation(final.get("result", ""))}
    init = next((e for e in events if e.get("type") == "thread.started"), {})
    final = next((e for e in reversed(events) if e.get("type") in
                  ["turn.completed", "turn.failed"]), {})
    return {"session_id": init.get("thread_id"), "model": None, "requested_model": "gpt-6.1-sol",
            "usage": final.get("usage"), "cost_usd": None,
            "terminal_event": final.get("type"),
            "native_error": final.get("type") != "turn.completed", "event_count": len(events),
            "interpretation": interpretation(" ".join(e.get("item", {}).get("text", "")
                 for e in events if e.get("item", {}).get("type") == "agent_message"))}


def interpretation(text):
    lower = text.lower()
    return {"old_head": "fixture-old-head" in text, "new_head": "fixture-new-head" in text,
            "mismatch": any(word in lower for word in ["differ", "mismatch", "not the same"]),
            "unbound_diff": any(word in lower for word in ["not head-pinned", "not pinned", "not bound", "unpinned"])}


def capture(command, directory, environment):
    process = subprocess.Popen(command, cwd=directory, env=environment,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    exceeded = threading.Event()

    def drain(name, stream):
        while True:
            chunk = stream.read(4096)
            if not chunk:
                break
            remaining = 4_000_000 - len(buffers[name])
            buffers[name].extend(chunk[:max(remaining, 0)])
            if len(chunk) > remaining:
                exceeded.set()
                process.kill()
                break

    threads = [threading.Thread(target=drain, args=(name, getattr(process, name)), daemon=True)
               for name in buffers]
    for thread in threads:
        thread.start()
    terminal = "returned"
    try:
        process.wait(timeout=90)
    except subprocess.TimeoutExpired:
        terminal = "timeout"
        process.kill()
        process.wait(timeout=5)
    for thread in threads:
        thread.join(timeout=1)
    if exceeded.is_set():
        terminal = "output_limit"
    if any(thread.is_alive() for thread in threads):
        terminal = "capture_incomplete"
    return process.returncode, terminal, {k: bytes(v).decode("utf-8", errors="replace")
                                         for k, v in buffers.items()}


def run(config):
    records = []
    lock = threading.Lock()
    backend = urllib.parse.urlsplit(config["url"])

    class Proxy(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            self.forward()

        def do_GET(self):
            self.forward()

        def do_DELETE(self):
            self.forward()

        def forward(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if len(body) > 100_000 or body.lstrip().startswith(b"["):
                self.send_error(400, "batch_or_body_limit")
                return
            requests = objects(body)
            request = requests[0] if requests and isinstance(requests[0], dict) else {}
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in ["host", "content-length", "connection"]}
            connection = http.client.HTTPConnection(backend.hostname, backend.port, timeout=30)
            try:
                connection.request(self.command, backend.path, body=body, headers=headers)
                response = connection.getresponse()
                output = response.read()
                # Restrict experiment discovery to the four compared compiled tools.
                if request.get("method") == "tools/list" and response.status == 200:
                    values = objects(output)
                    if len(values) == 1 and isinstance(values[0], dict):
                        result = values[0].get("result", {})
                        result["tools"] = [t for t in result.get("tools", []) if t["name"] in TOOLS]
                        payload = json.dumps(values[0]).encode()
                        output = b"data: " + payload + b"\n\n" if output.lstrip().startswith(b"data:") or b"event:" in output[:100] else payload
                row = observation(request, response.status, output)
                with lock:
                    if len(records) < 512:
                        records.append(row)
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in ["content-length", "transfer-encoding", "connection"]:
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(output)))
                self.end_headers()
                self.wfile.write(output)
            finally:
                connection.close()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d/mcp" % server.server_port
    provider = config["provider"]
    repo = config["repo"]
    if config["scenario"] == "original":
        instruction = ("Call each of repo_view_pr, repo_pr_checks, repo_pr_diff exactly once, "
                       "using repo=" + repo + " and number=9. Do not use read_composition.")
    else:
        args = {"request": {"action": "invoke", "name": "pr_review_context",
                            "arguments": {"repo": repo, "number": 9}}}
        instruction = "Call read_composition exactly once with arguments " + json.dumps(args) + "."
    prompt = (instruction + " Use only these MCP tools, no shell, files or other calls. "
              "Then quote both exact returned head revisions and briefly report whether they differ; "
              "the diff is not head-pinned. Report any error or partial status honestly; do not retry.")
    with tempfile.TemporaryDirectory(prefix="custode-native-") as directory:
        os.chmod(directory, 0o700)
        environment = dict(os.environ)
        environment.pop("CLAUDECODE", None)
        if provider == "claude":
            path = os.path.join(directory, "mcp.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"mcpServers": {"custode": {"type": "http", "url": url,
                            "headers": {"Authorization": "Bearer " + config["token"]}}}}, handle)
            os.chmod(path, 0o600)
            command = ["claude", "-p", prompt, "--model", "sonnet", "--tools", "",
                       "--allowedTools", ",".join("mcp__custode__" + t for t in TOOLS),
                       "--mcp-config", path, "--strict-mcp-config", "--setting-sources", "",
                       "--settings", '{"disableAllHooks":true}', "--disable-slash-commands",
                       "--no-chrome", "--no-session-persistence", "--permission-mode", "dontAsk",
                       "--max-turns", "5", "--max-budget-usd", "0.60", "--output-format", "stream-json", "--verbose"]
        else:
            environment["CUSTODE_NATIVE_PROOF_TOKEN"] = config["token"]
            command = ["codex", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
                       "--sandbox", "read-only", "--skip-git-repo-check", "--json", "--model",
                       "gpt-6.1-sol", "-c", 'model_reasoning_effort="low"',
                       "-c", 'approval_policy="never"', "-c", 'web_search="disabled"',
                       "-c", 'features.shell_tool=false', "-c", 'features.multi_agent=false',
                       "-c", "mcp_servers.custode.url=" + json.dumps(url),
                       "-c", 'mcp_servers.custode.bearer_token_env_var="CUSTODE_NATIVE_PROOF_TOKEN"',
                       "-c", "mcp_servers.custode.enabled_tools=" + json.dumps(TOOLS),
                       "-c", 'mcp_servers.custode.default_tools_approval_mode="approve"',
                       "-c", 'mcp_servers.custode.required=true', prompt]
        version = subprocess.run([provider, "--version"], capture_output=True, text=True,
                                 timeout=10, check=False).stdout.strip()
        started = time.monotonic()
        try:
            code, terminal, captured = capture(command, directory, environment)
            native_duration = round((time.monotonic() - started) * 1000)
            metadata = native_metadata(provider, captured["stdout"])
            for channel, value in captured.items():
                log_path = os.path.join(config["private_logs"], provider + "-" + config["scenario"] + "-" + channel + ".jsonl")
                descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    handle.write(value)
            metadata["exit_code"] = code
            metadata["capture"] = terminal
            metadata["stderr_bytes"] = len(captured["stderr"].encode())
        finally:
            server.shutdown()
            server.server_close()
        return {"provider": provider, "version": version, "scenario": config["scenario"],
                "native_duration_ms": native_duration,
                "client": metadata, "http": records,
                "settlement": "bounded_process_group_return_not_all_descendants_attested",
                "operator_corrections": "no_interactive_corrections_in_this_protocol",
                "cost_limit": "Claude requested stop 0.60 USD" if provider == "claude" else "unavailable",
                "catalog": "four_tool_proxy_projection"}


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as handle:
        print(json.dumps(run(json.load(handle))))
