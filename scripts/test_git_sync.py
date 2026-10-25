#!/usr/bin/env python3
"""scripts/git-sync.sh against a local bare remote: fast-forward, rebase of diverged .env commits, push guard, conflict abort."""
import os, pathlib, subprocess, tempfile, unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "git-sync.sh"
ENV = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, capture_output=True, text=True, check=True).stdout.strip()


class GitSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.origin, self.repo, self.other = t / "origin.git", t / "repo", t / "other"
        git(t, "init", "-q", "--bare", "-b", "main", str(self.origin))
        git(t, "clone", "-q", str(self.origin), str(self.repo))
        git(t, "clone", "-q", str(self.origin), str(self.other))
        (self.repo / ".env").write_text("A=1\n\nB=2\n")
        (self.repo / "app.txt").write_text("v1\n")
        (self.repo / "dashboard.json").write_text("orig\n")
        git(self.repo, "add", "."); git(self.repo, "commit", "-q", "-m", "init"); git(self.repo, "push", "-q", "-u", "origin", "HEAD:main")
        git(self.repo, "branch", "-q", "--set-upstream-to=origin/main", "main")
        git(self.other, "pull", "-q", "origin", "main")

    def sync(self, *args):
        return subprocess.run([str(SCRIPT), *args], env={**ENV, "GITOPS_REPO": str(self.repo)}, capture_output=True, text=True)

    def commit(self, repo, name, text, msg):
        (repo / name).write_text(text); git(repo, "add", name); git(repo, "commit", "-q", "-m", msg)

    def test_fast_forward(self):
        self.commit(self.other, "app.txt", "v2\n", "bump"); git(self.other, "push", "-q", "origin", "HEAD:main")
        r = self.sync()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.repo / "app.txt").read_text(), "v2\n")

    def test_diverged_env_commit_is_rebased_and_pushed(self):
        self.commit(self.repo, ".env", "A=1\n\nB=2\nC=3\n", "env: set C")
        self.commit(self.other, "app.txt", "v2\n", "deploy bump"); git(self.other, "push", "-q", "origin", "HEAD:main")
        r = self.sync("--push-env")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(git(self.origin, "log", "--format=%s", "main").split("\n"), ["env: set C", "deploy bump", "init"])
        self.assertEqual(git(self.repo, "status", "-sb").split("\n")[0], "## main...origin/main")

    def test_without_push_flag_nothing_is_pushed(self):
        self.commit(self.repo, ".env", "A=1\n\nB=2\nC=3\n", "env: set C")
        self.assertEqual(self.sync().returncode, 0)
        self.assertEqual(git(self.origin, "log", "--format=%s", "main"), "init")

    def test_commits_touching_other_files_are_never_pushed(self):
        self.commit(self.repo, ".env", "A=1\n\nB=2\nC=3\n", "env: set C")
        self.commit(self.repo, "app.txt", "wip\n", "unfinished work")
        r = self.sync("--push-env")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(git(self.origin, "log", "--format=%s", "main"), "init")

    def test_unrelated_uncommitted_edit_survives_rebase(self):
        self.commit(self.repo, ".env", "A=1\n\nB=2\nC=3\n", "env: set C")
        self.commit(self.other, "app.txt", "v2\n", "bump"); git(self.other, "push", "-q", "origin", "HEAD:main")
        (self.repo / "dashboard.json").write_text("edited\n")  # tracked file modified in the working tree, like host-health.json
        r = self.sync("--push-env")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.repo / "dashboard.json").read_text(), "edited\n")

    def test_conflict_aborts_cleanly_and_does_not_push(self):
        self.commit(self.repo, ".env", "A=1\n\nB=2\nLOCAL=1\n", "env: set LOCAL")
        self.commit(self.other, ".env", "A=1\n\nB=2\nREMOTE=1\n", "env: set REMOTE"); git(self.other, "push", "-q", "origin", "HEAD:main")
        r = self.sync("--push-env")
        self.assertEqual(r.returncode, 1)
        self.assertIn("rebase onto origin failed", r.stderr)
        self.assertFalse((self.repo / ".git" / "rebase-merge").exists())
        self.assertEqual(git(self.origin, "log", "--format=%s", "main").split("\n")[0], "env: set REMOTE")


if __name__ == "__main__":
    unittest.main()
