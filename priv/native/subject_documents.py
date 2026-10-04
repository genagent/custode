"""Custode's optional POSIX descriptor helper. JSON data only; fixed local Git reads never execute client commands."""
from contextlib import contextmanager
import difflib
import hashlib
import json
import os
import re
import resource
import select
import shutil
import signal
import subprocess
import struct
import tempfile
import time
import stat
import sys
import uuid
import zlib

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


# Fixed local Git reads operate only on a private, descriptor-copied object store.
MAX_GIT_ENTRIES = 5000
MAX_GIT_BYTES = 10_000_000
MAX_GIT_OBJECT_BYTES = 64_000
MAX_GIT_EXPANDED_BYTES = 10_000_000
MAX_GIT_OUTPUT = 64_000
MAX_GIT_HISTORY = 20
MAX_GIT_DIFF = 32_000


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def git_process_limits():
    if sys.platform != "darwin":
        resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024, 256 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))


class GitSnapshot:
    def __init__(self, root):
        self.root = root
        self.git_fd = self.objects_fd = None
        self.temporary = None
        self.deadline = time.monotonic() + 3.5
        self.entries = self.bytes = self.expanded = 0

    def __enter__(self):
        self.executable = shutil.which("git")
        if self.executable is None:
            raise Refused("git_executable_unavailable")
        self.root.check_binding()
        try:
            self.git_fd = os.open(".git", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                  dir_fd=self.root.fd)
            self.git_binding = identity(self.git_fd)
            if self.present(self.git_fd, "commondir"):
                raise Refused("git_linked_store_unavailable")
            self.objects_fd = os.open("objects", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                      dir_fd=self.git_fd)
            self.objects_binding = identity(self.objects_fd)
            self.head = self.read_head()
            self.temporary = tempfile.TemporaryDirectory(prefix="custode-subject-git-")
            self.directory = self.temporary.name
            os.mkdir(self.directory + "/objects")
            os.mkdir(self.directory + "/refs")
            with open(self.directory + "/config", "w") as output:
                output.write("[core]\nrepositoryformatversion = 0\nbare = true\n")
            with open(self.directory + "/HEAD", "w") as output:
                output.write((self.head or "ref: refs/heads/snapshot") + "\n")
            self.copy_objects()
            self.check()
            return self
        except OSError:
            self.close()
            raise Refused("git_repository_or_metadata_unavailable") from None
        except BaseException:
            self.close()
            raise

    def __exit__(self, *_error):
        self.close()

    def close(self):
        for fd in (self.objects_fd, self.git_fd):
            if fd is not None:
                os.close(fd)
        self.objects_fd = self.git_fd = None
        if self.temporary is not None:
            self.temporary.cleanup()
            self.temporary = None

    @staticmethod
    def present(parent, name):
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def check_time(self):
        if time.monotonic() >= self.deadline:
            raise Refused("git_time_limit")

    def check_binding(self):
        self.root.check_binding()
        for parent, name, expected in [(self.root.fd, ".git", self.git_binding),
                                       (self.git_fd, "objects", self.objects_binding)]:
            info = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode) or {"device": info.st_dev, "inode": info.st_ino} != expected:
                raise Refused("git_metadata_replaced")

    def check(self):
        self.check_time()
        self.check_binding()
        if self.read_head() != self.head:
            raise Refused("git_head_changed_during_read")
        self.check_binding()

    def metadata(self, relative, limit):
        parent, opened, chain = self.git_fd, [], []
        try:
            for part in relative.split("/")[:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                dir_fd=parent)
                chain.append((parent, part, child))
                opened.append(child)
                parent = child
            leaf = relative.split("/")[-1]
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
                    raise Refused("git_metadata_limit_or_type")
                data = b""
                while len(data) <= limit:
                    chunk = os.read(fd, min(4096, limit + 1 - len(data)))
                    if not chunk:
                        break
                    data += chunk
                current = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                if len(data) > limit or stamp(before) != stamp(os.fstat(fd)) or stamp(before) != stamp(current):
                    raise Refused("git_metadata_changed_during_read")
                for ancestor, part, child in chain:
                    info = os.stat(part, dir_fd=ancestor, follow_symlinks=False)
                    if not stat.S_ISDIR(info.st_mode) or (info.st_dev, info.st_ino) != stamp(os.fstat(child))[:2]:
                        raise Refused("git_metadata_replaced")
                return data
            finally:
                os.close(fd)
        finally:
            for fd in reversed(opened):
                os.close(fd)

    def read_head(self):
        value = self.metadata("HEAD", 1024).decode("ascii").strip()
        if re.fullmatch(r"[0-9a-f]{40}", value):
            return value
        if not value.startswith("ref: refs/"):
            raise Refused("git_head_format_unavailable")
        reference = value[5:]
        parts = reference.split("/")
        if any(not part or part in (".", "..") or "\\" in part for part in parts):
            raise Refused("git_ref_format_unavailable")
        try:
            value = self.metadata(reference, 1024).decode("ascii").strip()
        except FileNotFoundError:
            try:
                packed = self.metadata("packed-refs", MAX_GIT_OUTPUT).decode("ascii")
            except FileNotFoundError:
                return None
            matches = [line.split(" ", 1)[0] for line in packed.splitlines()
                       if " " in line and line.split(" ", 1)[1] == reference]
            if not matches:
                return None
            if len(matches) != 1:
                raise Refused("git_ref_format_unavailable")
            value = matches[0]
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise Refused("git_sha1_ref_required")
        return value

    def copy_objects(self):
        with os.scandir(self.objects_fd) as entries:
            for entry in entries:
                self.count_entry()
                if entry.name == "info":
                    fd = os.open("info", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                                 dir_fd=self.objects_fd)
                    try:
                        if any(self.present(fd, name) for name in ("alternates", "http-alternates")):
                            raise Refused("git_alternates_unavailable")
                    finally:
                        os.close(fd)
                    continue
                if entry.name != "pack" and not re.fullmatch(r"[0-9a-f]{2}", entry.name):
                    raise Refused("git_object_layout_unavailable")
                fd = os.open(entry.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                             dir_fd=self.objects_fd)
                target = self.directory + "/objects/" + entry.name
                os.mkdir(target)
                try:
                    with os.scandir(fd) as objects:
                        for item in objects:
                            self.count_entry()
                            pattern = r"pack-[0-9a-f]{40}\.(pack|idx|rev|bitmap|promisor)" if entry.name == "pack" else r"[0-9a-f]{38}"
                            if not re.fullmatch(pattern, item.name):
                                raise Refused("git_object_layout_unavailable")
                            if entry.name == "pack" and not item.name.endswith((".pack", ".idx")):
                                if not item.is_file(follow_symlinks=False):
                                    raise Refused("git_object_layout_unavailable")
                                continue
                            destination = target + "/" + item.name
                            self.copy_file(fd, item.name, destination)
                            self.validate_object(destination, entry.name != "pack")
                    after = os.stat(entry.name, dir_fd=self.objects_fd, follow_symlinks=False)
                    if not stat.S_ISDIR(after.st_mode) or stamp(after)[:2] != stamp(os.fstat(fd))[:2]:
                        raise Refused("git_metadata_replaced")
                finally:
                    os.close(fd)

    def count_entry(self):
        self.check_time()
        self.entries += 1
        if self.entries > MAX_GIT_ENTRIES:
            raise Refused("git_object_entry_limit")

    def copy_file(self, parent, name, destination):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_size > MAX_GIT_BYTES - self.bytes:
                raise Refused("git_object_byte_limit_or_type")
            with open(destination, "xb") as output:
                while True:
                    self.check_time()
                    chunk = os.read(fd, min(8192, MAX_GIT_BYTES + 1 - self.bytes))
                    if not chunk:
                        break
                    self.bytes += len(chunk)
                    if self.bytes > MAX_GIT_BYTES:
                        raise Refused("git_object_byte_limit_or_type")
                    output.write(chunk)
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if stamp(before) != stamp(os.fstat(fd)) or stamp(before) != stamp(current):
                raise Refused("git_object_changed_during_read")
        finally:
            os.close(fd)

    def validate_object(self, destination, loose):
        with open(destination, "rb") as source:
            data = source.read(MAX_GIT_BYTES + 1)
        try:
            if loose:
                inflater = zlib.decompressobj()
                expanded = inflater.decompress(data, MAX_GIT_OBJECT_BYTES + 1)
                if len(expanded) > MAX_GIT_OBJECT_BYTES:
                    raise Refused("git_expanded_object_limit")
                if not inflater.eof or inflater.unused_data:
                    raise Refused("git_object_format_unavailable")
                header, content = expanded.split(b"\0", 1)
                kind, length = header.split(b" ", 1)
                if kind not in (b"blob", b"tree", b"commit", b"tag") or not length.isdigit() or int(length) != len(content):
                    raise Refused("git_object_format_unavailable")
                if hashlib.sha1(expanded).hexdigest() != os.path.basename(os.path.dirname(destination)) + os.path.basename(destination):
                    raise Refused("git_object_format_unavailable")
                self.count_expanded(len(expanded))
            elif destination.endswith(".pack"):
                self.validate_pack(data)
            elif destination.endswith(".idx"):
                self.validate_index(data)
        except (zlib.error, ValueError, IndexError, struct.error):
            raise Refused("git_object_format_unavailable") from None

    def count_expanded(self, size):
        self.expanded += size
        if self.expanded > MAX_GIT_EXPANDED_BYTES:
            raise Refused("git_expanded_store_limit")

    def validate_pack(self, data):
        if len(data) < 32 or data[:4] != b"PACK" or hashlib.sha1(data[:-20]).digest() != data[-20:]:
            raise Refused("git_pack_format_unavailable")
        version, count = struct.unpack("!II", data[4:12])
        if version not in (2, 3) or count > MAX_GIT_ENTRIES:
            raise Refused("git_pack_format_unavailable")
        position = 12
        for _index in range(count):
            self.check_time()
            byte = data[position]
            position += 1
            kind, size, shift = (byte >> 4) & 7, byte & 15, 4
            while byte & 128:
                if shift > 25:
                    raise Refused("git_expanded_object_limit")
                byte = data[position]
                position += 1
                size |= (byte & 127) << shift
                shift += 7
            if kind in (6, 7):
                raise Refused("git_delta_store_unavailable")
            if kind not in (1, 2, 3, 4) or size > MAX_GIT_OBJECT_BYTES:
                raise Refused("git_expanded_object_limit")
            inflater = zlib.decompressobj()
            expanded = inflater.decompress(data[position:], MAX_GIT_OBJECT_BYTES + 1)
            if len(expanded) > MAX_GIT_OBJECT_BYTES:
                raise Refused("git_expanded_object_limit")
            if not inflater.eof or len(expanded) != size:
                raise Refused("git_pack_format_unavailable")
            position += len(data) - position - len(inflater.unused_data)
            self.count_expanded(size)
        if position != len(data) - 20:
            raise Refused("git_pack_format_unavailable")

    def validate_index(self, data):
        version = 1
        offset = 0
        if data[:4] == b"\xfftOc":
            version = struct.unpack("!I", data[4:8])[0]
            offset = 8
        if version not in (1, 2) or len(data) < offset + 1024 + 40:
            raise Refused("git_index_format_unavailable")
        fanout = struct.unpack("!256I", data[offset:offset + 1024])
        count = fanout[-1]
        record_bytes = 24 if version == 1 else 28
        if count > MAX_GIT_ENTRIES or list(fanout) != sorted(fanout) or len(data) != offset + 1024 + record_bytes * count + 40:
            raise Refused("git_index_format_unavailable")
        if hashlib.sha1(data[:-20]).digest() != data[-20:]:
            raise Refused("git_index_format_unavailable")
        if version == 2:
            positions = data[offset + 1024 + 24 * count:offset + 1024 + 28 * count]
            if any(value & 0x80000000 for value in struct.unpack("!" + "I" * count, positions)):
                raise Refused("git_large_pack_index_unavailable")

    def run(self, arguments, limit=MAX_GIT_OUTPUT):
        self.check_time()
        environment = {"LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": os.devnull,
                       "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ATTR_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0",
                       "GIT_LITERAL_PATHSPECS": "1", "GIT_NO_LAZY_FETCH": "1"}
        argv = [self.executable, "--no-pager", "--no-optional-locks", "--git-dir=" + self.directory,
                "-c", "core.hooksPath=" + os.devnull, "-c", "core.fsmonitor=false",
                "-c", "core.packedGitWindowSize=1m", "-c", "core.packedGitLimit=8m",
                "-c", "core.deltaBaseCacheLimit=1m"] + arguments
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=environment, cwd=self.directory,
                                   start_new_session=True, preexec_fn=git_process_limits)
        chunks, size = [], 0
        try:
            while True:
                wait = self.deadline - time.monotonic()
                if wait <= 0 or not select.select([process.stdout], [], [], wait)[0]:
                    raise Refused("git_time_limit")
                chunk = os.read(process.stdout.fileno(), min(4096, limit + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > limit:
                    raise Refused("git_output_limit")
            if process.wait(timeout=max(0.001, self.deadline - time.monotonic())) != 0:
                raise Refused("git_read_unavailable")
            return b"".join(chunks)
        except subprocess.TimeoutExpired:
            raise Refused("git_time_limit") from None
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except PermissionError:
                    process.kill()
                except ProcessLookupError:
                    pass
                process.wait(timeout=1)
            process.stdout.close()

    def blob(self, relative):
        if self.head is None:
            return None, b""
        tree = self.run(["ls-tree", "-z", self.head, "--", relative])
        if not tree:
            return None, b""
        records = tree.rstrip(b"\0").split(b"\0")
        if len(records) != 1:
            raise Refused("git_path_ambiguous")
        metadata, path = records[0].split(b"\t", 1)
        mode, kind, oid = metadata.split(b" ")
        if path != relative.encode() or mode not in (b"100644", b"100755") or kind != b"blob":
            raise Refused("git_historical_regular_file_required")
        oid = oid.decode("ascii")
        size = self.run(["cat-file", "-s", oid], 100).strip()
        if not size.isdigit() or int(size) > MAX_BYTES:
            raise Refused("git_blob_byte_limit")
        return oid, self.run(["cat-file", "blob", oid], MAX_BYTES)

    def history(self, relative):
        if self.head is None:
            return []
        data = self.run(["log", "--max-count=21", "--format=%H%x00%ct", "--no-renames", self.head, "--", relative])
        entries = []
        for line in data.splitlines():
            oid, at = line.split(b"\0")
            if not re.fullmatch(rb"[0-9a-f]{40}", oid) or not re.fullmatch(rb"-?[0-9]{1,12}", at):
                raise Refused("git_history_format_unavailable")
            entries.append({"git_revision": oid.decode("ascii"), "committed_at_unix": int(at)})
        return entries


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

    def git_read(self, action, relative):
        with self.parent(relative) as (parent, leaf, chain):
            fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
            try:
                before = os.fstat(fd)
                if not stat.S_ISREG(before.st_mode):
                    raise Refused("regular_file_required")
                return self.git_result(action, relative, fd, parent, leaf, chain, before)
            finally:
                os.close(fd)

    def git_result(self, action, relative, fd, parent, leaf, chain, before):
        current = self.read(relative)
        try:
            with GitSnapshot(self) as snapshot:
                result = {key: current[key] for key in ("path", "revision", "bytes")}
                result.update({"git_revision": snapshot.head, "read_only": True,
                               "consistency": "pinned_git_snapshot_and_verified_current_file",
                               "process_memory": "expanded_input_and_cache_limits_no_hard_rss_attestation"})
                if action == "history":
                    history = snapshot.history(relative)
                    result.update({"history": history[:MAX_GIT_HISTORY], "has_more": len(history) > MAX_GIT_HISTORY,
                                   "rename_following": False, "source": "path_scoped_git_history_current_bytes_revision"})
                else:
                    oid, previous = snapshot.blob(relative)
                    try:
                        text = previous.decode("utf-8")
                    except UnicodeDecodeError:
                        raise Refused("git_blob_invalid_utf8") from None
                    diff = "".join(difflib.unified_diff(text.splitlines(True), current["content"].splitlines(True),
                                                        fromfile="HEAD/" + relative, tofile="working/" + relative))
                    if len(diff.encode()) > MAX_GIT_DIFF:
                        raise Refused("git_diff_byte_limit")
                    result.update({"diff": diff, "git_blob_id": oid, "tracked_at_head": oid is not None,
                                   "base_revision": hashlib.sha256(previous).hexdigest() if oid else None,
                                   "comparison": "pinned_head_to_current_working_bytes", "source": "git_head_and_current_working_bytes"})
                snapshot.check()
                named = os.stat(leaf, dir_fd=parent, follow_symlinks=False)
                if stamp(before) != stamp(os.fstat(fd)) or stamp(before) != stamp(named):
                    raise Refused("document_changed_during_git_read")
                self.check_chain(chain)
                snapshot.check_binding()
                if len(json.dumps(result, ensure_ascii=True).encode()) > MAX_FRAME - 100:
                    raise Refused("git_result_limit")
                return result
        except (OSError, subprocess.SubprocessError):
            raise Refused("git_repository_or_metadata_unavailable") from None

    def invoke(self, request):
        action = request.get("action")
        if action in ("history", "diff"):
            return self.git_read(action, request["path"])
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
        except (OSError, ValueError, KeyError, TypeError, OverflowError):
            # No exception repr: it may include private paths or content.
            emit({"ok": False, "error": "filesystem_or_protocol_refused"})


if __name__ == "__main__":
    main()
