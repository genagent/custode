"""Adversarial tests against the production descriptor helper, not a second implementation."""
import importlib.util
import os
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


if __name__ == "__main__":
    unittest.main()
