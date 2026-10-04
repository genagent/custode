"""Adversarial tests against the production descriptor helper, not a second implementation."""
import importlib.util
import os
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("subject_documents", Path(__file__).resolve().parents[2] / "priv/native/subject_documents.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DescriptorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.path = self.base / "root"
        self.path.mkdir()
        self.outside = self.base / "outside"
        self.outside.mkdir()
        (self.outside / "secret.md").write_text("outside secret")
        (self.path / "source.md").write_text("authorized source")
        self.root = MODULE.Root(str(self.path), None)

    def tearDown(self):
        os.close(self.root.fd)
        self.temporary.cleanup()

    def test_first_binding_refuses_symlinked_root_or_parent(self):
        linked = self.base / "link"
        linked.symlink_to(self.outside, target_is_directory=True)
        for path in [linked, linked / "nested"]:
            with self.assertRaises(OSError):
                MODULE.Root(str(path), None)

    def test_symlink_swap_between_binding_check_and_read_cannot_leak(self):
        real_open = os.open
        changed = False

        def racing_open(path, flags, *args, **kwargs):
            nonlocal changed
            if path == "source.md" and kwargs.get("dir_fd") == self.root.fd and not changed:
                changed = True
                (self.path / "source.md").unlink()
                (self.path / "source.md").symlink_to(self.outside / "secret.md")
            return real_open(path, flags, *args, **kwargs)

        with patch.object(MODULE.os, "open", side_effect=racing_open):
            with self.assertRaises(OSError):
                self.root.read("source.md")
        self.assertTrue(changed)

    def test_replacement_after_file_open_is_detected_before_return(self):
        real_read = os.read
        changed = False

        def racing_read(fd, size):
            nonlocal changed
            if not changed:
                changed = True
                (self.path / "source.md").rename(self.path / "prior.md")
                (self.path / "source.md").symlink_to(self.outside / "secret.md")
            return real_read(fd, size)

        with patch.object(MODULE.os, "read", side_effect=racing_read):
            with self.assertRaisesRegex(MODULE.Refused, "document_changed_during_read"):
                self.root.read("source.md")

    def test_root_swap_at_publication_only_touches_original_directory_identity(self):
        real_link = os.link

        def racing_link(source, destination, **kwargs):
            self.path.rename(self.base / "original-root")
            self.path.symlink_to(self.outside, target_is_directory=True)
            return real_link(source, destination, **kwargs)

        with patch.object(MODULE.os, "link", side_effect=racing_link):
            with self.assertRaisesRegex(MODULE.Refused, "root_replaced"):
                self.root.create("result.md", "bounded result")
        self.assertFalse((self.outside / "result.md").exists())
        self.assertEqual((self.base / "original-root" / "result.md").read_text(), "bounded result")

    def test_temporary_replacement_cannot_be_claimed_as_our_publication(self):
        real_link = os.link

        def racing_link(source, destination, **kwargs):
            (self.path / source).unlink()
            (self.path / source).symlink_to(self.outside / "secret.md")
            return real_link(source, destination, **kwargs)

        with patch.object(MODULE.os, "link", side_effect=racing_link):
            with self.assertRaisesRegex(MODULE.Refused, "publication_changed"):
                self.root.create("result.md", "our bytes")
        self.assertTrue((self.path / "result.md").is_symlink())
        self.assertEqual((self.outside / "secret.md").read_text(), "outside secret")
        with self.assertRaises(OSError):
            self.root.read("result.md")

    def test_exclusive_publication_never_overwrites_a_file_or_symlink(self):
        for destination in ["source.md", "linked.md"]:
            if destination == "linked.md":
                (self.path / destination).symlink_to(self.outside / "secret.md")
            with self.assertRaises(FileExistsError):
                self.root.create(destination, "replacement")
        self.assertEqual((self.path / "source.md").read_text(), "authorized source")
        self.assertEqual((self.outside / "secret.md").read_text(), "outside secret")

    def test_bounded_browse_and_search_fail_instead_of_scanning_everything(self):
        for i in range(7):
            (self.path / f"large-{i}.md").write_text("x" * 16_384)
        with self.assertRaisesRegex(MODULE.Refused, "search_budget"):
            self.root.invoke({"action": "search", "query": "x", "allowed_paths": "all"})
        for i in range(102):
            (self.path / f"many-{i}.md").write_text("x")
        with self.assertRaisesRegex(MODULE.Refused, "browse_limit"):
            self.root.browse("all")
        self.assertEqual(self.root.browse(["source.md"]), ["source.md"])

    def nested_source(self):
        directory = self.path / "research"
        directory.mkdir()
        (directory / "source.md").write_text("nested authorized source")
        return directory

    def test_nested_operations_share_current_content_and_exact_destinations(self):
        directory = self.nested_source()
        (self.path / "plans").mkdir()
        source = self.root.read("research/source.md")
        self.assertEqual(source["content"], "nested authorized source")
        self.assertEqual(self.root.browse(["research/source.md"]), ["research/source.md"])
        self.assertEqual(self.root.browse("all"), ["research/source.md", "source.md"])
        self.assertEqual(self.root.invoke({"action": "search", "query": "nested", "allowed_paths": "all"})["matches"][0]["path"], "research/source.md")
        proposal = self.root.invoke({"action": "propose", "path": "research/source.md",
                                    "destination": "plans/proposal.md", "expected_revision": source["revision"],
                                    "content": "changed"})
        self.assertFalse(proposal["applied"])
        self.assertEqual((directory / "source.md").read_text(), "nested authorized source")
        self.assertTrue((self.path / "plans/proposal.md").is_file())
        with self.assertRaises(FileExistsError):
            self.root.create("plans/proposal.md", "overwrite")

    def test_nested_symlinks_and_noncanonical_paths_are_refused(self):
        self.nested_source()
        (self.path / "linked").symlink_to(self.outside, target_is_directory=True)
        for relative in ["linked/secret.md", "research/../source.md", "research//source.md",
                         "/source.md", "research/.git/secret.md", "./source.md", "research/hidden\\secret.md"]:
            with self.subTest(relative=relative):
                with self.assertRaises((MODULE.Refused, OSError)):
                    self.root.read(relative)
        self.assertNotIn("linked/secret.md", self.root.browse("all"))
        with self.assertRaises(FileNotFoundError):
            self.root.create("missing/new.md", "no implicit directories")
        self.assertFalse((self.path / "missing").exists())

    def test_ancestor_symlink_swap_before_open_cannot_leak(self):
        directory = self.nested_source()
        real_open = os.open
        changed = False

        def racing_open(path, flags, *args, **kwargs):
            nonlocal changed
            if path == "research" and kwargs.get("dir_fd") == self.root.fd and not changed:
                changed = True
                directory.rename(self.base / "original-research")
                directory.symlink_to(self.outside, target_is_directory=True)
            return real_open(path, flags, *args, **kwargs)

        with patch.object(MODULE.os, "open", side_effect=racing_open):
            with self.assertRaises(OSError):
                self.root.read("research/source.md")
        self.assertTrue(changed)

    def test_ancestor_replacement_during_read_is_refused_before_return(self):
        directory = self.nested_source()
        real_read = os.read
        changed = False

        def racing_read(fd, size):
            nonlocal changed
            if not changed:
                changed = True
                directory.rename(self.base / "original-research")
                directory.mkdir()
                (directory / "source.md").write_text("replacement directory source")
            return real_read(fd, size)

        with patch.object(MODULE.os, "read", side_effect=racing_read):
            with self.assertRaisesRegex(MODULE.Refused, "directory_replaced"):
                self.root.read("research/source.md")

    def test_ancestor_swap_at_publication_cannot_redirect_or_confirm_output(self):
        directory = self.nested_source()
        real_link = os.link

        def racing_link(source, destination, **kwargs):
            directory.rename(self.base / "original-research")
            directory.symlink_to(self.outside, target_is_directory=True)
            return real_link(source, destination, **kwargs)

        with patch.object(MODULE.os, "link", side_effect=racing_link):
            with self.assertRaisesRegex(MODULE.Refused, "directory_replaced"):
                self.root.create("research/result.md", "bounded result")
        self.assertFalse((self.outside / "result.md").exists())
        self.assertEqual((self.base / "original-research/result.md").read_text(), "bounded result")
        self.assertFalse(any(path.name.startswith(".custode-") for path in (self.base / "original-research").iterdir()))

    def test_browse_ancestor_swap_during_scan_is_refused(self):
        directory = self.nested_source()
        real_scandir = os.scandir
        changed = False

        def racing_scandir(fd):
            nonlocal changed
            result = real_scandir(fd)
            if fd != self.root.fd and not changed:
                changed = True
                directory.rename(self.base / "original-research")
                directory.symlink_to(self.outside, target_is_directory=True)
            return result

        with patch.object(MODULE.os, "scandir", side_effect=racing_scandir):
            with self.assertRaisesRegex(MODULE.Refused, "directory_replaced"):
                self.root.browse("all")
        self.assertTrue(changed)

    def test_recursive_browse_and_search_share_global_budgets(self):
        for i in range(7):
            directory = self.path / f"area-{i}"
            directory.mkdir()
            (directory / "large.md").write_text("x" * MODULE.MAX_BYTES)
        with self.assertRaisesRegex(MODULE.Refused, "search_budget"):
            self.root.invoke({"action": "search", "query": "x", "allowed_paths": "all"})
        with patch.object(MODULE, "MAX_SCAN", 5):
            with self.assertRaisesRegex(MODULE.Refused, "directory_scan_limit"):
                self.root.browse("all")
        with patch.object(MODULE, "MAX_NAMES", 5):
            with self.assertRaisesRegex(MODULE.Refused, "browse_limit"):
                self.root.browse("all")
        self.assertEqual(self.root.browse(["source.md"]), ["source.md"])

    def test_maximum_depth_unicode_and_hidden_trees(self):
        directory = self.path
        for _i in range(MODULE.MAX_DEPTH - 1):
            directory = directory / "notes"
            directory.mkdir()
        relative = "notes/" * (MODULE.MAX_DEPTH - 1) + "été.md"
        result = self.root.create(relative, "retained source")
        self.assertEqual(self.root.read(relative)["revision"], result["revision"])
        hidden = self.path / ".git"
        hidden.mkdir()
        (hidden / "private.md").write_text("private")
        self.assertEqual(self.root.browse("all"), [relative, "source.md"])
        with self.assertRaisesRegex(MODULE.Refused, "relative_markdown_path_required"):
            self.root.read(".git/private.md")
        with self.assertRaisesRegex(MODULE.Refused, "invalid_name"):
            self.root.create("é" * 99 + ".md", "over byte limit")

    def test_depth_bound_and_ungranted_tree_pruning(self):
        directory = self.path
        for _i in range(MODULE.MAX_DEPTH):
            directory = directory / "nested"
            directory.mkdir()
        (directory / "deep.md").write_text("too deep")
        with self.assertRaisesRegex(MODULE.Refused, "directory_depth_limit"):
            self.root.browse("all")
        with self.assertRaisesRegex(MODULE.Refused, "relative_markdown_path_required"):
            self.root.read("nested/" * MODULE.MAX_DEPTH + "deep.md")
        self.assertEqual(self.root.browse(["source.md"]), ["source.md"])


class GitDescriptorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.path = self.base / "root"
        self.path.mkdir()
        (self.path / "research").mkdir()
        self.document = self.path / "research/source.md"
        self.document.write_text("committed source\n")
        self.git("init", "--quiet")
        self.git("add", "research/source.md")
        self.commit("initial")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.root = MODULE.Root(str(self.path), None)

    def tearDown(self):
        os.close(self.root.fd)
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.check_output(["git", *arguments], cwd=self.path, stderr=subprocess.DEVNULL).decode()

    def commit(self, message):
        self.git("-c", "user.name=Docs", "-c", "user.email=docs@example.test", "commit", "--quiet", "-m", message)

    def test_real_history_and_working_diff_preserve_head_index_and_unrelated_work(self):
        (self.path / "unrelated.md").write_text("staged unrelated\n")
        self.git("add", "unrelated.md")
        (self.path / "unrelated.md").write_text("unstaged unrelated\n")
        self.document.write_text("current human source\n")
        index = (self.path / ".git/index").read_bytes()
        status = self.git("status", "--porcelain")
        history = self.root.invoke({"action": "history", "path": "research/source.md"})
        diff = self.root.invoke({"action": "diff", "path": "research/source.md"})
        self.assertEqual(history["history"], [{"git_revision": self.head, "committed_at_unix": int(self.git("show", "-s", "--format=%ct", "HEAD"))}])
        self.assertFalse(history["has_more"])
        self.assertFalse(history["rename_following"])
        self.assertEqual(diff["revision"], MODULE.hashlib.sha256(self.document.read_bytes()).hexdigest())
        self.assertIn("-committed source", diff["diff"])
        self.assertIn("+current human source", diff["diff"])
        self.assertEqual(diff["git_revision"], self.head)
        self.assertTrue(diff["read_only"])
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.head)
        self.assertEqual((self.path / ".git/index").read_bytes(), index)
        self.assertEqual(self.git("status", "--porcelain"), status)
        self.assertFalse(any(item.name.startswith("custode-subject-git-") for item in self.path.iterdir()))

    def test_unborn_untracked_and_packed_stores_keep_source_and_head_distinct(self):
        self.git("gc", "--quiet")
        self.document.write_text("after packing\n")
        self.assertEqual(self.root.git_read("diff", "research/source.md")["git_revision"], self.head)
        new = self.path / "new.md"
        new.write_text("new untracked source\n")
        diff = self.root.git_read("diff", "new.md")
        self.assertFalse(diff["tracked_at_head"])
        self.assertIsNone(diff["base_revision"])
        self.assertIn("+new untracked source", diff["diff"])
        self.assertEqual(self.root.git_read("history", "new.md")["history"], [])
        self.git("update-ref", "-d", "refs/heads/" + self.git("branch", "--show-current").strip())
        self.assertIsNone(self.root.git_read("diff", "new.md")["git_revision"])

    def test_repository_config_external_diff_textconv_hooks_and_attributes_never_execute(self):
        marker = self.base / "executed"
        executable = self.base / "plugin"
        executable.write_text("#!/bin/sh\ntouch '" + str(marker) + "'\n")
        executable.chmod(0o700)
        self.git("config", "diff.external", str(executable))
        self.git("config", "diff.untrusted.textconv", str(executable))
        self.git("config", "core.hooksPath", str(self.base))
        self.git("config", "include.path", str(self.base / "private-config"))
        (self.base / "private-config").write_text("[alias]\nsecret = private-account-data\n")
        (self.path / ".gitattributes").write_text("*.md diff=untrusted\n")
        self.document.write_text("changed current source\n")
        result = self.root.git_read("diff", "research/source.md")
        self.assertIn("+changed current source", result["diff"])
        self.assertNotIn("private-account-data", str(result))
        self.assertFalse(marker.exists())

    def test_caps_cover_objects_output_history_and_decompressed_historical_blob(self):
        for key, error in [("MAX_GIT_ENTRIES", "git_object_entry_limit"), ("MAX_GIT_BYTES", "git_object_byte_limit")]:
            with patch.object(MODULE, key, 1):
                with self.assertRaisesRegex(MODULE.Refused, error):
                    self.root.git_read("history", "research/source.md")
        with MODULE.GitSnapshot(self.root) as snapshot:
            with self.assertRaisesRegex(MODULE.Refused, "git_output_limit"):
                snapshot.run(["log", "--format=%H", self.head], limit=1)
        self.document.write_text("x" * (MODULE.MAX_BYTES + 1))
        self.git("add", "research/source.md")
        self.commit("large historical content")
        self.document.write_text("bounded current source\n")
        with self.assertRaisesRegex(MODULE.Refused, "git_blob_byte_limit"):
            self.root.git_read("diff", "research/source.md")
        with MODULE.GitSnapshot(self.root) as snapshot:
            snapshot.deadline = 0
            with self.assertRaisesRegex(MODULE.Refused, "git_time_limit"):
                snapshot.run(["log", "--format=%H", self.head])

    def test_no_history_follows_a_rename_to_an_old_ungranted_path(self):
        self.git("mv", "research/source.md", "new.md")
        self.commit("rename source")
        renamed = self.git("rev-parse", "HEAD").strip()
        history = self.root.git_read("history", "new.md")
        self.assertEqual([item["git_revision"] for item in history["history"]], [renamed])
        self.assertNotIn(self.head, str(history))
        self.assertFalse(history["rename_following"])

    def test_alternates_gitfiles_and_symlinked_objects_are_explicitly_unavailable(self):
        alternates = self.path / ".git/objects/info/alternates"
        alternates.write_text(str(self.base / "outside-objects") + "\n")
        with self.assertRaisesRegex(MODULE.Refused, "git_alternates_unavailable"):
            self.root.git_read("history", "research/source.md")
        alternates.unlink()
        object_file = next(item for item in (self.path / ".git/objects").glob("??/*") if item.is_file())
        outside = self.base / "outside-object"
        object_file.rename(outside)
        object_file.symlink_to(outside)
        with self.assertRaisesRegex(MODULE.Refused, "git_repository_or_metadata_unavailable"):
            self.root.git_read("history", "research/source.md")
        object_file.unlink()
        outside.rename(object_file)
        (self.path / ".git").rename(self.base / "git-store")
        (self.path / ".git").write_text("gitdir: " + str(self.base / "git-store") + "\n")
        with self.assertRaisesRegex(MODULE.Refused, "git_repository_or_metadata_unavailable"):
            self.root.git_read("history", "research/source.md")

    def test_missing_git_and_absent_repository_fail_without_inventing_history(self):
        with patch.object(MODULE.shutil, "which", return_value=None):
            with self.assertRaisesRegex(MODULE.Refused, "git_executable_unavailable"):
                self.root.git_read("history", "research/source.md")
        (self.path / ".git").rename(self.base / "saved-git")
        with self.assertRaisesRegex(MODULE.Refused, "git_repository_or_metadata_unavailable"):
            self.root.git_read("history", "research/source.md")

    def test_metadata_root_and_current_ancestor_replacement_during_git_cannot_confirm(self):
        real_run = MODULE.GitSnapshot.run
        for replaced, error in [("git", "git_metadata_replaced"), ("ancestor", "directory_replaced"), ("root", "root_replaced")]:
            changed = False
            def racing_run(snapshot, *args, **kwargs):
                nonlocal changed
                result = real_run(snapshot, *args, **kwargs)
                if not changed:
                    changed = True
                    if replaced == "git":
                        (self.path / ".git").rename(self.path / "old-git")
                        (self.path / ".git").mkdir()
                    elif replaced == "ancestor":
                        (self.path / "research").rename(self.path / "old-research")
                        (self.path / "research").mkdir()
                        self.document.write_text("committed source\n")
                    else:
                        self.path.rename(self.base / "old-root")
                        self.path.mkdir()
                        (self.path / "research").mkdir()
                        self.document.write_text("committed source\n")
                return result
            with patch.object(MODULE.GitSnapshot, "run", racing_run):
                with self.assertRaisesRegex(MODULE.Refused, error):
                    self.root.git_read("history", "research/source.md")
            self.assertTrue(changed)
            if replaced == "git":
                (self.path / ".git").rmdir()
                (self.path / "old-git").rename(self.path / ".git")
            elif replaced == "ancestor":
                self.document.unlink()
                (self.path / "research").rmdir()
                (self.path / "old-research").rename(self.path / "research")

    def test_identical_source_replacement_and_head_change_are_refused(self):
        real_run = MODULE.GitSnapshot.run
        changed = False
        def racing_run(snapshot, *args, **kwargs):
            nonlocal changed
            result = real_run(snapshot, *args, **kwargs)
            if not changed:
                changed = True
                self.document.rename(self.path / "old-source.md")
                self.document.write_text("committed source\n")
            return result
        with patch.object(MODULE.GitSnapshot, "run", racing_run):
            with self.assertRaisesRegex(MODULE.Refused, "document_changed_during_git_read"):
                self.root.git_read("history", "research/source.md")
        self.document.write_text("next commit\n")
        self.git("add", "research/source.md")
        self.commit("next")
        changed = False
        def head_run(snapshot, *args, **kwargs):
            nonlocal changed
            result = real_run(snapshot, *args, **kwargs)
            if not changed:
                changed = True
                self.git("update-ref", "HEAD", self.head)
            return result
        with patch.object(MODULE.GitSnapshot, "run", head_run):
            with self.assertRaisesRegex(MODULE.Refused, "git_head_changed_during_read"):
                self.root.git_read("history", "research/source.md")


    def test_inflation_bombs_and_delta_or_malformed_packs_are_refused_before_git(self):
        loose = b"blob 1000000\0" + b"x" * 1_000_000
        oid = MODULE.hashlib.sha1(loose).hexdigest()
        directory = self.path / ".git/objects" / oid[:2]
        directory.mkdir(exist_ok=True)
        object_file = directory / oid[2:]
        object_file.write_bytes(MODULE.zlib.compress(loose))
        with patch.object(MODULE.GitSnapshot, "run", side_effect=AssertionError("Git must not run")):
            with self.assertRaisesRegex(MODULE.Refused, "git_expanded_object_limit"):
                self.root.git_read("history", "research/source.md")
        object_file.unlink()
        pack_dir = self.path / ".git/objects/pack"
        for body, error in [(bytes([0x60]), "git_delta_store_unavailable"), (bytes([0x00]), "git_expanded_object_limit")]:
            data = b"PACK" + MODULE.struct.pack("!II", 2, 1) + body
            checksum = MODULE.hashlib.sha1(data).digest()
            pack = pack_dir / ("pack-" + checksum.hex() + ".pack")
            pack.write_bytes(data + checksum)
            with patch.object(MODULE.GitSnapshot, "run", side_effect=AssertionError("Git must not run")):
                with self.assertRaisesRegex(MODULE.Refused, error):
                    self.root.git_read("history", "research/source.md")
            pack.unlink()

    def test_object_replacement_while_copying_and_symlinked_ref_never_redirect_metadata(self):
        object_file = next(item for item in (self.path / ".git/objects").glob("??/*") if item.is_file())
        original = object_file.stat()
        real_read = os.read
        changed = False
        outside = self.base / "outside-object"
        outside.write_bytes(b"outside private bytes")
        def racing_read(fd, size):
            nonlocal changed
            info = os.fstat(fd)
            if not changed and (info.st_dev, info.st_ino) == (original.st_dev, original.st_ino):
                changed = True
                object_file.rename(self.base / "original-object")
                object_file.symlink_to(outside)
            return real_read(fd, size)
        with patch.object(MODULE.os, "read", side_effect=racing_read):
            with self.assertRaisesRegex(MODULE.Refused, "git_object_changed_during_read"):
                self.root.git_read("history", "research/source.md")
        self.assertTrue(changed)
        object_file.unlink()
        (self.base / "original-object").rename(object_file)
        reference = (self.path / ".git/HEAD").read_text().strip()[5:]
        ref_file = self.path / ".git" / reference
        ref_file.unlink()
        ref_file.symlink_to(outside)
        with self.assertRaisesRegex(MODULE.Refused, "git_repository_or_metadata_unavailable"):
            self.root.git_read("history", "research/source.md")
        self.assertEqual(outside.read_bytes(), b"outside private bytes")

    def test_history_limit_reports_more_without_inventing_complete_results(self):
        self.document.write_text("next source\n")
        self.git("add", "research/source.md")
        self.commit("next")
        with patch.object(MODULE, "MAX_GIT_HISTORY", 1):
            history = self.root.git_read("history", "research/source.md")
        self.assertEqual(len(history["history"]), 1)
        self.assertTrue(history["has_more"])


if __name__ == "__main__":
    unittest.main()
