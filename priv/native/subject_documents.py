"""Custode's optional POSIX descriptor helper. JSON data only; no commands or imports from clients."""
from contextlib import contextmanager
import difflib
import hashlib
import json
import os
import stat
import sys
import uuid

MAX_BYTES = 16_384
MAX_NAMES = 100
MAX_DEPTH = 8
MAX_SCAN = 500
MAX_SEARCH_BYTES = 100_000
MAX_FRAME = 200_000


class Refused(Exception):
    pass


def name(value):
    if not isinstance(value, str) or len(value.encode()) > 200:
        raise Refused("invalid_name")
    parts = value.split("/")
    if (not value.endswith(".md") or len(parts) > MAX_DEPTH or "\\" in value
            or any(not part or part.startswith(".") for part in parts)
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise Refused("relative_markdown_path_required")
    return value


def identity(fd):
    info = os.fstat(fd)
    return {"device": info.st_dev, "inode": info.st_ino}


def open_root(path):
    # The configured directory itself is authority, not a mutable pathname.
    # Initial configuration may resolve a platform alias such as /var -> /private/var.
    if not isinstance(path, str) or not path.startswith("/"):
        raise Refused("absolute_configured_root_required")
    # Fixed, root-owned macOS aliases only. Never resolve an arbitrary symlink
    # from the configured directory or its mutable parent chain.
    resolved = path
    if sys.platform == "darwin":
        for alias in ("/var", "/tmp", "/etc"):
            if resolved == alias or resolved.startswith(alias + "/"):
                resolved = "/private" + resolved
                break
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for part in resolved.split("/"):
            if not part:
                continue
            if part in (".", "..", ".git"):
                raise Refused("root_component_refused")
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


class Root:
    def __init__(self, path, expected):
        if os.name != "posix":
            raise Refused("posix_required")
        self.path = path
        try:
            self.fd = open_root(path)
        except OSError:
            if expected is not None:
                raise Refused("root_replaced") from None
            raise
        self.binding = identity(self.fd)
        if expected is not None and expected != self.binding:
            os.close(self.fd)
            raise Refused("root_replaced")

    def check_binding(self):
        try:
            current = open_root(self.path)
        except OSError:
            raise Refused("root_replaced") from None
        try:
            if identity(current) != self.binding:
                raise Refused("root_replaced")
        finally:
            os.close(current)

    def check_chain(self, chain):
        self.check_binding()
        parent = self.fd
        opened = []
        try:
            for part, expected in chain:
                current = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                  dir_fd=parent)
                opened.append(current)
                if identity(current) != expected:
                    raise Refused("directory_replaced")
                parent = current
            self.check_binding()
        except OSError:
            raise Refused("directory_replaced") from None
        finally:
            for fd in reversed(opened):
                os.close(fd)

    @contextmanager
    def parent(self, relative):
        relative = name(relative)
        self.check_binding()
        fd, opened, chain = self.fd, [], []
        try:
            for part in relative.split("/")[:-1]:
                fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                             dir_fd=fd)
                opened.append(fd)
                chain.append((part, identity(fd)))
            self.check_chain(chain)
            yield fd, relative.split("/")[-1], chain
        finally:
            for child in reversed(opened):
                os.close(child)

    def read(self, relative, budget=MAX_BYTES):
        with self.parent(relative) as (parent, leaf, chain):
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode):
                    raise Refused("regular_file_required")
                limit = min(MAX_BYTES, budget)
                if info.st_size > limit:
                    raise Refused("search_budget" if limit < MAX_BYTES else "content_too_large")
                chunks, size = [], 0
                while size <= limit:
                    chunk = os.read(fd, min(4096, limit + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                if size > limit:
                    raise Refused("search_budget" if limit < MAX_BYTES else "content_too_large")
                data = b"".join(chunks)
                try:
                    content = data.decode("utf-8")
                except UnicodeDecodeError:
                    raise Refused("invalid_utf8") from None
                after = os.fstat(fd)
                current = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                original_stamp = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                after_stamp = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                if original_stamp != after_stamp or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    raise Refused("document_changed_during_read")
                self.check_chain(chain)
                return {"path": relative, "content": content,
                        "revision": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
            finally:
                os.close(fd)

    def browse(self, allowed):
        self.check_binding()
        found, scanned = [], 0

        def walk(fd, prefix, chain):
            nonlocal scanned
            with os.scandir(fd) as entries:
                for entry in entries:
                    scanned += 1
                    if scanned > MAX_SCAN:
                        raise Refused("directory_scan_limit")
                    if entry.name.startswith("."):
                        continue
                    relative = prefix + entry.name
                    if entry.is_dir(follow_symlinks=False):
                        if allowed != "all" and not any(path.startswith(relative + "/") for path in allowed):
                            continue
                        if len(chain) + 1 >= MAX_DEPTH:
                            raise Refused("directory_depth_limit")
                        # Validate components before descending, even for a directory named *.md.
                        name(relative + "/a.md")
                        child = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                        dir_fd=fd)
                        child_chain = chain + [(entry.name, identity(child))]
                        try:
                            self.check_chain(child_chain)
                            walk(child, relative + "/", child_chain)
                            self.check_chain(child_chain)
                        finally:
                            os.close(child)
                    elif (entry.name.endswith(".md") and entry.is_file(follow_symlinks=False)
                          and (allowed == "all" or relative in allowed)):
                        name(relative)
                        found.append(relative)
                        if len(found) > MAX_NAMES:
                            raise Refused("browse_limit")
            self.check_chain(chain)

        walk(self.fd, "", [])
        return sorted(found)

    def create(self, relative, content):
        if not isinstance(content, str) or len(content.encode()) > MAX_BYTES:
            raise Refused("content_too_large")
        with self.parent(relative) as (parent, leaf, chain):
            temporary = ".custode-" + uuid.uuid4().hex
            fd = os.open(temporary, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=parent)
            owned = identity(fd)
            try:
                with os.fdopen(fd, "wb", closefd=False) as output:
                    output.write(content.encode())
                    output.flush()
                    os.fsync(output.fileno())
                self.check_chain(chain)
                os.link(temporary, leaf, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
                published = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                if (published.st_dev, published.st_ino) != (owned["device"], owned["inode"]):
                    raise Refused("publication_changed")
                os.lseek(fd, 0, os.SEEK_SET)
                if os.read(fd, MAX_BYTES + 1) != content.encode():
                    raise Refused("publication_changed")
                self.check_chain(chain)
                os.fsync(parent)
            finally:
                os.close(fd)
                try:
                    temporary_info = os.stat(temporary, dir_fd=parent, follow_symlinks=False)
                    if (temporary_info.st_dev, temporary_info.st_ino) == (owned["device"], owned["inode"]):
                        os.unlink(temporary, dir_fd=parent)
                except FileNotFoundError:
                    pass
        # Return the bytes published, not a later external editor's version.
        data = content.encode()
        return {"path": relative, "content": content, "bytes": len(data),
                "revision": hashlib.sha256(data).hexdigest()}

    def invoke(self, request):
        action = request.get("action")
        if action == "read":
            return self.read(request["path"])
        if action == "browse":
            return {"paths": self.browse(request["allowed_paths"])}
        if action == "search":
            query = request["query"]
            if not isinstance(query, str) or not query or len(query.encode()) > 200:
                raise Refused("invalid_query")
            matches, total = [], 0
            for path in self.browse(request["allowed_paths"]):
                document = self.read(path, MAX_SEARCH_BYTES - total)
                total += document["bytes"]
                if total > MAX_SEARCH_BYTES:
                    raise Refused("search_budget")
                if query.casefold() in document["content"].casefold():
                    matches.append({k: document[k] for k in ("path", "revision", "bytes")})
            return {"matches": matches, "scanned_bytes": total}
        if action == "create":
            return self.create(request["path"], request["content"])
        if action == "propose":
            source = self.read(request["path"])
            if source["revision"] != request["expected_revision"]:
                raise Refused("stale_revision:" + source["revision"])
            replacement = request["content"]
            if not isinstance(replacement, str) or len(replacement.encode()) > MAX_BYTES:
                raise Refused("content_too_large")
            diff = "".join(difflib.unified_diff(source["content"].splitlines(True), replacement.splitlines(True),
                                               fromfile=request["path"], tofile=request["path"]))
            proposal = self.create(request["destination"], "# Proposed edit\nTarget: " + request["path"] +
                                   "\nExpected revision: " + source["revision"] + "\n\n```diff\n" + diff + "\n```\n")
            return {"proposal": proposal, "target": source["path"],
                    "expected_revision": source["revision"], "diff": diff, "applied": False}
        raise Refused("unsupported_operation")


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    root = None
    while True:
        line = sys.stdin.buffer.readline(MAX_FRAME + 1)
        if not line:
            return
        try:
            if len(line) > MAX_FRAME or not line.endswith(b"\n"):
                raise Refused("frame_limit")
            request = json.loads(line)
            if root is None:
                if request.get("action") != "bind":
                    raise Refused("root_required")
                root = Root(request["root"], request.get("expected"))
                result = {"binding": root.binding}
            else:
                result = root.invoke(request)
            emit({"ok": True, "result": result})
        except Refused as error:
            emit({"ok": False, "error": str(error)})
        except FileExistsError:
            emit({"ok": False, "error": "destination_exists"})
        except FileNotFoundError:
            emit({"ok": False, "error": "not_found"})
        except (OSError, ValueError, KeyError, TypeError):
            # No exception repr: it may include private paths or content.
            emit({"ok": False, "error": "filesystem_or_protocol_refused"})


if __name__ == "__main__":
    main()
