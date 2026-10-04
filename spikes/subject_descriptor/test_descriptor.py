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


if __name__ == "__main__":
    unittest.main()
