import pathlib
import subprocess
import tempfile
import unittest

from unittest.mock import patch
from upstream_metadata import FORK, gh, metadata, release_notes


class UpstreamMetadataTests(unittest.TestCase):
    def test_release_api_explicitly_targets_fork(self):
        with patch("upstream_metadata.subprocess.check_output", return_value="{}") as command:
            gh("release", "view")
        self.assertEqual(command.call_args.args[0][-2:], ["--repo", FORK])


    def test_labels_only_official_tags_contained_in_build(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = pathlib.Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repo, text=True, stderr=subprocess.DEVNULL).strip()
            def commit(name, content):
                (repo/name).write_text(content)
                git("add", name)
                git("commit", "-m", "fixture")
                return git("rev-parse", "HEAD")
            git("init", "-b", "main")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            official = commit("official", "first")
            git("tag", "upstream/1.6.20", official)
            fork = commit("enhancement", "retained")
            git("checkout", "-b", "official-next", official)
            future = commit("official", "future")
            git("tag", "upstream/1.6.21", future)
            git("tag", "upstream/Snapshot-2611210000", future)
            git("update-ref", "refs/remotes/upstream/main", future)
            values = metadata(fork, repo=repo)
            self.assertEqual(values, {"upstream_version":"1.6.20", "upstream_commit":official})

    def test_notes_replace_old_baseline_and_remain_idempotent(self):
        values = {"upstream_version":"1.6.20", "upstream_commit":"a"*40}
        notes = release_notes("Original notes.\nUpstream baseline: obsolete.\n", values)
        self.assertNotIn("obsolete", notes)
        self.assertIn("Original notes.", notes)
        self.assertEqual(release_notes(notes, values), notes)
        self.assertEqual(notes.count("Included official version:"), 1)


if __name__ == "__main__":
    unittest.main()
