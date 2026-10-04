"""Fixture-only subject application and HTTP MCP contract. Not production code."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

MAX_BYTES = 16384


class Refused(Exception):
    pass


class Documents:
    def __init__(self, root):
        self.root = Path(root).resolve(strict=True)
        self.lock = threading.Lock()

    def path(self, relative):
        if not isinstance(relative, str):
            raise Refused("invalid_path")
        parts = Path(relative).parts
        if not parts or Path(relative).is_absolute() or any(p in ("..", ".git") for p in parts):
            raise Refused("invalid_path")
        current = self.root
        for part in parts:
            current = current / part
            if current.is_symlink():
                raise Refused("symlink")
        if current.suffix != ".md":
            raise Refused("markdown_only")
        if not current.resolve().is_relative_to(self.root):
            raise Refused("outside_root")
        return current

    def read(self, path):
        data = self.path(path).read_bytes()
        if len(data) > MAX_BYTES:
            raise Refused("content_too_large")
        return {"path": path, "revision": hashlib.sha256(data).hexdigest(), "content": data.decode()}

    def browse(self):
        paths = []
        for directory, children, files in os.walk(self.root, followlinks=False):
            children[:] = [p for p in children if p != ".git" and not (Path(directory) / p).is_symlink()]
            for name in files:
                path = str((Path(directory) / name).relative_to(self.root))
                if name.endswith(".md"):
                    self.path(path)
                    paths.append(path)
        if len(paths) > 100:
            raise Refused("browse_limit")
        return sorted(paths)

    def create(self, path, content, actor):
        if not path.startswith("research/"):
            raise Refused("destination_not_granted")
        data = content.encode()
        if len(data) > MAX_BYTES:
            raise Refused("content_too_large")
        with self.lock:
            destination = self.path(path)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("xb") as output:
                output.write(data)
        return {**self.read(path), "producer": actor, "evidence": "authored_fixture"}

    def propose(self, path, expected_revision, content, actor):
        if len(content.encode()) > MAX_BYTES:
            raise Refused("content_too_large")
        with self.lock:
            old = self.read(path)
            if old["revision"] != expected_revision:
                raise Refused("stale_revision:" + old["revision"])
            diff = "".join(difflib.unified_diff(old["content"].splitlines(True), content.splitlines(True), fromfile=path, tofile=path))
            relative = "proposals/" + uuid4().hex + ".md"
            destination = self.path(relative)
            destination.parent.mkdir(exist_ok=True)
            with destination.open("x") as output:
                output.write(f"# Proposed edit\nActor: {actor}\nTarget: {path}\nExpected revision: {expected_revision}\n\n```diff\n{diff}```\n")
            return {"proposal": relative, "target": path, "expected_revision": expected_revision, "diff": diff, "applied": False}

    def history(self, path):
        self.path(path)
        return subprocess.check_output(["git", "--no-pager", "log", "-n", "5", "--format=%H %s", "--", path], cwd=self.root, text=True)

    def invoke(self, actor, tool, args):
        if tool == "context_browse":
            return {"paths": self.browse()}
        if tool == "context_read":
            return self.read(args["path"])
        if tool == "context_search":
            matches, total = [], 0
            for path in self.browse():
                if path.startswith("proposals/"):
                    continue
                document = self.read(path)
                total += len(document["content"].encode())
                if total > 100000:
                    raise Refused("search_budget")
                if args["query"].lower() in document["content"].lower():
                    matches.append({k: document[k] for k in ("path", "revision")})
            return {"matches": matches}
        if tool == "context_history":
            return {"history": self.history(args["path"])}
        if tool == "context_diff":
            self.path(args["path"])
            return {"diff": subprocess.check_output(["git", "--no-pager", "diff", "HEAD", "--", args["path"]], cwd=self.root, text=True)}
        if actor == "reader":
            raise Refused("read_only")
        if tool == "context_create":
            return self.create(args["path"], args["content"], actor)
        if tool == "context_propose":
            return self.propose(args["path"], args["expected_revision"], args["content"], actor)
        raise Refused("unknown_tool")


def serve(documents):
    identities = {"fixture-worker-one": "worker-one", "fixture-worker-two": "worker-two", "fixture-reader": "reader"}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            actor = identities.get(self.headers.get("Authorization", "").removeprefix("Bearer "))
            if actor is None:
                self.send_error(401)
                return
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            try:
                if request["method"] != "tools/call":
                    raise Refused("fixture_supports_tools_call_only")
                params = request["params"]
                value = documents.invoke(actor, params["name"], params.get("arguments", {}))
                result = {"content": [{"type": "text", "text": json.dumps(value)}]}
            except (Refused, FileNotFoundError, FileExistsError) as error:
                result = {"isError": True, "content": [{"type": "text", "text": str(error)}]}
            payload = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread
