#!/usr/bin/env python3
"""Write-only API behind butler.<domain>/_env/*: add or update one key in the dotenvx-encrypted .env.

GET  /_env/keys  -> [{"key": ..., "set": bool}]  names only, never values
POST /_env/set   -> {"key": ..., "value": ...}   runs `dotenvx set` (public key only), commits .env, then scripts/git-sync.sh
                                                   --push-env rebases onto origin and pushes it; GitOps applies it within ~1 minute

Runs as ubuntu on loopback; Caddy (private site) injects Tailscale-User-Login. It never reads .env.keys / dotenvx.keys.
Only keys listed in .env.example are accepted, so a new key needs an .env.example commit first.
"""
import hmac, json, os, pathlib, re, subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

REPO = pathlib.Path(os.environ.get("ENV_API_REPO") or pathlib.Path(__file__).resolve().parent.parent)
# Rendered by dotenv-env.sh or owned by dotenvx: never settable from here.
DENY = {"DOTENV_PUBLIC_KEY", "TAILSCALE_IP", "BUTLER_ORIGIN", "BUTLER_WEB_ORIGIN"}
GIT_ID = ["-c", "user.name=Ubuntu", "-c", "user.email=ubuntu@localhost.localdomain"]


def allowed_keys(repo=REPO):
    names = re.findall(r"^([A-Z][A-Z0-9_]*)=", (repo / ".env.example").read_text(), re.M)
    return [k for k in dict.fromkeys(names) if k not in DENY and not k.startswith("DOTENV_")]


def is_set(key, repo=REPO):
    return re.search(rf"^{key}=", (repo / ".env").read_text(), re.M) is not None


def set_key(key, value, repo=REPO):
    """Returns (http_status, message). Never echoes the value."""
    if key not in allowed_keys(repo):
        return 400, "key is not in .env.example (or is rendered/reserved)"
    if not isinstance(value, str) or not 1 <= len(value) <= 4096 or re.search(r"[\x00-\x1f\x7f]", value):
        return 400, "value must be 1-4096 chars, single line"
    # ponytail: dotenvx has no stdin mode, so the value sits in argv for ~100ms (readable via /proc by other local users).
    run = subprocess.run(["dotenvx", "set", "-f", ".env", key, "--", value], cwd=repo, capture_output=True, timeout=20)
    if run.returncode:
        return 500, "dotenvx set failed"
    # Commit only .env: the checkout has unrelated uncommitted work. The value in .env is dotenvx-encrypted, so pushing it to the public origin is safe.
    commit = subprocess.run(["git", *GIT_ID, "commit", "-q", "-m", f"env: set {key}", "--only", "--", ".env"],
                            cwd=repo, capture_output=True, timeout=20)
    if commit.returncode:
        return 500, "key was set in .env but the commit failed; commit .env manually"
    sync = repo / "scripts" / "git-sync.sh"
    if not os.access(sync, os.X_OK):
        return 200, f"{key} saved and committed locally (no git-sync.sh to push it)"
    try:
        pushed = subprocess.run([str(sync), "--push-env"], cwd=repo, capture_output=True, timeout=90).returncode == 0
    except subprocess.TimeoutExpired:
        pushed = False
    if pushed:
        return 200, f"{key} saved and pushed; applied by the next gitops run (about a minute)"
    # The gitops timer runs git-sync.sh --push-env every minute, so a failed push here is retried there.
    return 200, f"{key} saved and committed; push failed, gitops will retry it"


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        login, origin = os.environ["BUTLER_LOGIN"], os.environ["BUTLER_WEB_ORIGIN"]
        got = self.headers.get("Tailscale-User-Login", "")
        if not hmac.compare_digest(got.encode(), login.encode()) or self.headers.get("Host") != urlparse(origin).netloc:
            return False
        # Cross-site writes (CSRF) are rejected by Origin; requiring JSON also forces a CORS preflight.
        return self.command == "GET" or (self.headers.get("Origin") == origin
                                         and self.headers.get("Content-Type", "").split(";")[0] == "application/json")

    def do_GET(self):
        if not self.authorized():
            return self.reply(403, {"error": "forbidden"})
        if self.path != "/_env/keys":
            return self.reply(404, {"error": "not found"})
        self.reply(200, [{"key": k, "set": is_set(k, REPO)} for k in allowed_keys(REPO)])

    def do_POST(self):
        if not self.authorized():
            return self.reply(403, {"error": "forbidden"})
        if self.path != "/_env/set":
            return self.reply(404, {"error": "not found"})
        try:
            size = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(size)) if 0 < size <= 8192 else {}
        except ValueError:
            body = {}
        code, msg = set_key(body.get("key"), body.get("value"), REPO)
        self.reply(code, {"ok": code == 200, "message": msg})

    def log_message(self, fmt, *args):  # request line + status only; bodies (values) are never logged
        print(f"{self.command} {self.path} {args[1] if len(args) > 1 else ''}", flush=True)


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(os.environ.get("ENV_API_PORT", "8791"))), Handler).serve_forever()
