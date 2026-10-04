"""Nonpaid installed-host observation. No inference, thread/start or turn/start methods."""
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit


def settle_group(process):
    # A detached descendant may escape this group; this is not physical attestation.
    for action in [signal.SIGTERM, signal.SIGKILL]:
        try:
            os.killpg(process.pid, action)
        except ProcessLookupError:
            pass
        if action == signal.SIGTERM:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
    process.wait(timeout=3)


def command(argv, env, cwd, output_limit=512_000, timeout=15):
    process = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    observed = 0
    deadline = time.monotonic() + timeout
    try:
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while selector.get_map():
            if time.monotonic() >= deadline:
                raise TimeoutError("native observation deadline")
            for key, _events in selector.select(timeout=min(.1, max(0, deadline - time.monotonic()))):
                data = os.read(key.fileobj.fileno(), 65_536)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                observed += len(data)
                if observed > output_limit:
                    raise RuntimeError("native observation output bound exceeded")
                if key.data == "stdout":
                    stdout.extend(data)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("native observation deadline")
        code = process.wait(timeout=remaining)
        return code, stdout.decode(errors="replace")
    finally:
        selector.close()
        settle_group(process)
        process.stdout.close()
        process.stderr.close()


def publish(url, revision=2):
    request = urllib.request.Request(url.rsplit("/mcp", 1)[0] + f"/control/catalog/{revision}",
                                     data=b"", headers={"Authorization": "Bearer fixture-owner"})
    with urllib.request.urlopen(request, timeout=3) as response:
        assert response.status == 200


def inventory(response):
    if "error" in response:
        return {"state": "unavailable", "error_code": response["error"].get("code")}
    servers = response.get("result", {}).get("data", [])
    selected = [s for s in servers if s["name"] == "fixture799"]
    if len(selected) != 1:
        return {"state": "unavailable", "reason": "fixture status missing"}
    server = selected[0]
    return {"state": "observed", "tools": sorted(server.get("tools", {})),
            "resources": sorted(r["name"] for r in server.get("resources", [])),
            "resource_templates": sorted(r["name"] for r in server.get("resourceTemplates", [])),
            "capabilities": server.get("serverCapabilities"),
            "runtime_status": server.get("runtimeStatus"),
            "tools_error": server.get("toolsError") is not None}


class AppServer:
    def __init__(self, binary, env, cwd):
        self.process = subprocess.Popen([binary, "app-server", "--stdio"], env=env, cwd=cwd,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.bytes = 0
        try:
            self.request("initialize", {"clientInfo": {"name": "nonpaid-catalog-proof", "version": "1"}}, 1)
            self.send({"method": "initialized"})
        except BaseException:
            self.close()
            raise

    def send(self, request):
        self.process.stdin.write(json.dumps(request).encode() + b"\n")
        self.process.stdin.flush()

    def request(self, method, params, request_id):
        if method not in {"initialize", "mcpServerStatus/list"}:
            raise ValueError("nonpaid method allowlist")
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if message.get("id") == request_id:
                    return message
            if not self.selector.select(timeout=.2):
                continue
            data = os.read(self.process.stdout.fileno(), 65_536)
            if not data:
                raise RuntimeError("nonpaid app-server ended before response")
            self.bytes += len(data)
            if self.bytes > 512_000:
                raise RuntimeError("nonpaid app-server output bound exceeded")
            self.buffer += data
        raise TimeoutError("nonpaid app-server response deadline")

    def close(self):
        self.selector.close()
        settle_group(self.process)
        self.process.stdin.close()
        self.process.stdout.close()


def claude_health(url, env, directory):
    config = dict(env, CLAUDE_CONFIG_DIR=str(Path(directory) / "claude-config"))
    binary = shutil.which("claude")
    server = {"type": "http", "url": url, "headers": {"Authorization": "Bearer fixture-owner"}}
    code, _output = command([binary, "mcp", "add-json", "fixture799", json.dumps(server), "--scope", "local"], config, directory)
    if code != 0:
        return {"state": "unavailable", "setup_exit_code": code}
    observations = []
    for revision in [1, 2]:
        publish(url, revision)
        code, output = command([binary, "mcp", "list"], config, directory)
        observations.append({"fixture_revision": revision, "exit_code": code,
                             "connected_health_message": "Connected" in output and "fixture799" in output})
    return {"state": "observed", "mode": "fresh MCP health-check process per revision",
            "observations": observations, "catalog_contents": "not exposed by health-check output",
            "long_lived_refresh": "unknown", "model_calls": 0}


def main(url):
    endpoint = urlsplit(url)
    if (endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1" or endpoint.port is None
            or endpoint.username is not None or endpoint.password is not None
            or endpoint.path != "/mcp" or endpoint.query or endpoint.fragment):
        raise ValueError("controlled loopback endpoint required")
    binary = shutil.which("codex")
    with tempfile.TemporaryDirectory(prefix="custode-catalog-") as directory:
        root = Path(directory)
        env = {k: v for k, v in os.environ.items() if k in {"PATH", "USER", "TMPDIR", "LANG", "LC_ALL"}}
        env["CODEX_HOME"] = str(root)
        (root / "config.toml").write_text('[mcp_servers.fixture799]\nurl = ' + json.dumps(url) + '\nhttp_headers = { Authorization = "Bearer fixture-owner" }\n')
        claude = claude_health(url, env, directory)
        publish(url, 1)
        app = AppServer(binary, env, directory)
        try:
            before = inventory(app.request("mcpServerStatus/list", {}, 2))
            publish(url)
            repeated = inventory(app.request("mcpServerStatus/list", {}, 3))
        finally:
            app.close()
        fresh = AppServer(binary, env, directory)
        try:
            reconnected = inventory(fresh.request("mcpServerStatus/list", {}, 2))
        finally:
            fresh.close()
        return {"claude": claude, "provider": "codex", "mode": "nonpaid app-server status, no thread or turn",
                "before": before, "same_process_second_status": repeated, "fresh_process_status": reconnected,
                "long_lived_native_connection_refresh": "unknown; status lookup may reconnect",
                "model_calls": 0, "physical_settlement": "process-group cleanup, not all-descendant attestation"}


if __name__ == "__main__":
    def deadline(_signal, _frame):
        raise TimeoutError("nonpaid overall observation deadline")
    signal.signal(signal.SIGALRM, deadline)
    signal.alarm(90)
    try:
        print(json.dumps(main(sys.argv[1]), sort_keys=True))
    except Exception as error:
        print(json.dumps({"state": "unavailable", "error_class": type(error).__name__, "model_calls": 0}))
        raise SystemExit(1)
