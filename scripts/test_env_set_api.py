import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import HTTPServer

SCRIPT = pathlib.Path(__file__).with_name("env-set-api.py")
spec = importlib.util.spec_from_file_location("env_set_api", SCRIPT)
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)

ORIGIN = "https://butler.example.com"
LOGIN = "me@example.com"
REAL_ENV = SCRIPT.parent.parent / ".env"  # encrypted, public-key only: safe to copy


@unittest.skipUnless(shutil.which("dotenvx") and REAL_ENV.exists(), "needs dotenvx and the committed .env")
class EnvSetApiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name)
        shutil.copy(REAL_ENV, self.repo / ".env")
        (self.repo / ".env.example").write_text("FOO_KEY=x\nTAILSCALE_IP=\nBUTLER_ORIGIN=x\n# COMMENTED=1\nBAR_KEY=y\n")
        (self.repo / "other.txt").write_text("unrelated\n")
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run([*git, "add", ".env", ".env.example"], cwd=self.repo, check=True)
        subprocess.run([*git, "commit", "-q", "-m", "init"], cwd=self.repo, check=True)
        subprocess.run(["git", "add", "other.txt"], cwd=self.repo, check=True)  # staged but must not be committed
        self.before = (self.repo / ".env").read_text()

    def tearDown(self):
        self.tmp.cleanup()

    def git_out(self, *a):
        return subprocess.run(["git", *a], cwd=self.repo, capture_output=True, text=True, check=True).stdout

    def test_allowlist_excludes_rendered_and_commented(self):
        self.assertEqual(api.allowed_keys(self.repo), ["FOO_KEY", "BAR_KEY"])

    def test_set_encrypts_and_commits_only_env(self):
        code, msg = api.set_key("FOO_KEY", 'p@ss "w0rd" $x', self.repo)
        self.assertEqual(code, 200, msg)
        after = (self.repo / ".env").read_text()
        self.assertIn('FOO_KEY="encrypted:', after)
        self.assertNotIn("w0rd", after)
        self.assertNotIn("w0rd", msg)
        self.assertTrue(api.is_set("FOO_KEY", self.repo))
        self.assertEqual(self.git_out("show", "--name-only", "--format=%s", "HEAD").split(), ["env:", "set", "FOO_KEY", ".env"])
        self.assertFalse(self.git_out("diff", "--name-only").strip().startswith(".env"))
        self.assertTrue(set(self.before.splitlines()) <= set(after.splitlines()) | {l for l in self.before.splitlines() if l.startswith("FOO_KEY")})
        self.assertFalse((self.repo / ".env.keys").exists())

    def stub_sync(self, exit_code):
        (self.repo / "scripts").mkdir(exist_ok=True)
        stub = self.repo / "scripts" / "git-sync.sh"
        stub.write_text(f'#!/bin/sh\necho "$@" > "{self.repo}/sync-args"\nexit {exit_code}\n')
        stub.chmod(0o755)
        return self.repo / "sync-args"

    def test_pushes_through_git_sync_after_committing(self):
        args = self.stub_sync(0)
        code, msg = api.set_key("FOO_KEY", "v", self.repo)
        self.assertEqual(code, 200, msg)
        self.assertEqual(args.read_text().strip(), "--push-env")
        self.assertIn("pushed", msg)

    def test_failed_push_still_reports_saved_and_retried_by_gitops(self):
        self.stub_sync(1)
        code, msg = api.set_key("FOO_KEY", "v", self.repo)
        self.assertEqual(code, 200, msg)
        self.assertTrue(api.is_set("FOO_KEY", self.repo))
        self.assertIn("push failed, gitops will retry", msg)

    def test_rejects_bad_input(self):
        for key, value in [("NOT_LISTED", "v"), ("TAILSCALE_IP", "v"), ("DOTENV_PUBLIC_KEY", "v"), ("FOO_KEY", ""),
                           ("FOO_KEY", "a\nb"), ("FOO_KEY", 5), ("FOO_KEY", "x" * 5000), (None, "v")]:
            self.assertEqual(api.set_key(key, value, self.repo)[0], 400, (key, value))
        self.assertEqual((self.repo / ".env").read_text(), self.before)

    def serve(self):
        os.environ.update(BUTLER_LOGIN=LOGIN, BUTLER_WEB_ORIGIN=ORIGIN)
        api.REPO = self.repo
        srv = HTTPServer(("127.0.0.1", 0), api.Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.addCleanup(srv.shutdown)
        return srv.server_address[1]

    def call(self, port, method, path, body=None, **headers):
        h = {"Host": "butler.example.com", "Tailscale-User-Login": LOGIN, **headers}
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    def test_http_auth_and_csrf(self):
        port = self.serve()
        post = dict(body={"key": "FOO_KEY", "value": "v1"}, Origin=ORIGIN, **{"Content-Type": "application/json"})
        self.assertEqual(self.call(port, "GET", "/_env/keys")[1], [{"key": "FOO_KEY", "set": False}, {"key": "BAR_KEY", "set": False}])
        self.assertEqual(self.call(port, "GET", "/_env/keys", **{"Tailscale-User-Login": "evil@x.com"})[0], 403)
        self.assertEqual(self.call(port, "GET", "/_env/keys", Host="evil.example.com")[0], 403)
        self.assertEqual(self.call(port, "POST", "/_env/set", **{**post, "Origin": "https://evil.com"})[0], 403)
        self.assertEqual(self.call(port, "POST", "/_env/set", **{**post, "Content-Type": "text/plain"})[0], 403)
        self.assertEqual((self.repo / ".env").read_text(), self.before)
        status, body = self.call(port, "POST", "/_env/set", **post)
        self.assertEqual((status, body["ok"]), (200, True))
        self.assertEqual(self.call(port, "GET", "/_env/keys")[1][0], {"key": "FOO_KEY", "set": True})


if __name__ == "__main__":
    unittest.main()
