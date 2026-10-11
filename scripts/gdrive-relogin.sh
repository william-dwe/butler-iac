#!/usr/bin/env bash
# Google Drive login for the off-box backup (rclone remote "gdrive", scope drive.file). Run as root.
#   gdrive-relogin.sh --setup            first time: prompts for OAuth client id/secret, then the pasted redirect address
#   gdrive-relogin.sh --print-url        print the consent URL for the configured client (used by backup-notify.sh)
#   gdrive-relogin.sh '<address|code>'   exchange the code from http://127.0.0.1:53682/?code=... for a new token
# The redirect page will not load (nothing listens on 127.0.0.1:53682); copy the address from the browser bar.
# Works with a Desktop-app client, or a Web client that lists http://127.0.0.1:53682/ as a redirect URI.
# Secrets are never printed. Tests can point GOOGLE_TOKEN_URL at a stub.
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }
cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
# Program passed with -c (not via stdin) so --setup can read the terminal.
prog=$(cat <<'PY'
import getpass, json, os, sys, tempfile, time, urllib.parse, urllib.request
cfg, args = sys.argv[1], sys.argv[2:]
conf = os.path.join(cfg, "rclone.conf")
env = os.path.join(cfg, "backup.env")
redirect = "http://127.0.0.1:53682/"
scope = "drive.file"
token_url = os.environ.get("GOOGLE_TOKEN_URL", "https://oauth2.googleapis.com/token")

def read_conf():
    vals, sect = {}, None
    if os.path.exists(conf):
        for line in open(conf):
            line = line.rstrip("\n")
            if line.startswith("["):
                sect = line.strip("[]")
            elif sect == "gdrive" and "=" in line:
                k, v = line.split("=", 1)
                vals[k.strip()] = v.strip()
    return vals

def write_file(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)

def write_conf(v):
    lines = ["[gdrive]", "type = drive", f"client_id = {v['client_id']}", f"client_secret = {v['client_secret']}",
             f"scope = {scope}"]
    if v.get("token"):
        lines.append(f"token = {v['token']}")
    write_file(conf, "\n".join(lines) + "\n")

def auth_url(cid):
    q = urllib.parse.urlencode({"client_id": cid, "redirect_uri": redirect, "response_type": "code",
                                "scope": f"https://www.googleapis.com/auth/{scope}",
                                "access_type": "offline", "prompt": "consent"})
    return "https://accounts.google.com/o/oauth2/v2/auth?" + q

def extract_code(s):
    s = s.strip().strip("'\"")
    if s.startswith("http"):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(s).query)
        if "error" in q:
            sys.exit(f"Google returned an error: {q['error'][0]}")
        if "code" not in q:
            sys.exit("no code= in that address")
        return q["code"][0]
    return s

def exchange(v, code):
    data = urllib.parse.urlencode({"code": code, "client_id": v["client_id"], "client_secret": v["client_secret"],
                                   "redirect_uri": redirect, "grant_type": "authorization_code"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(token_url, data=data), timeout=30) as r:
            tok = json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        try:
            body = json.loads(body).get("error_description") or json.loads(body).get("error") or "error"
        except Exception:
            body = "error"
        sys.exit(f"token exchange failed ({e.code}): {body}")
    if "refresh_token" not in tok:
        sys.exit("Google returned no refresh_token (open the link again; it forces consent)")
    exp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() + int(tok.get("expires_in", 3600)))) + ".000000000Z"
    return json.dumps({"access_token": tok["access_token"], "token_type": tok.get("token_type", "Bearer"),
                       "refresh_token": tok["refresh_token"], "expiry": exp}, separators=(",", ":"))

def ensure_env():
    if not os.path.exists(env):
        write_file(env, f"REMOTE_RESTIC_REPOSITORY=rclone:gdrive:agent-state\nRCLONE_CONFIG={conf}\nRCLONE_DRIVE_USE_TRASH=false\n")
        print(f"wrote {env}")

if args[:1] == ["--print-url"]:
    v = read_conf()
    if not v.get("client_id"):
        sys.exit("no client_id configured (run --setup)")
    print(auth_url(v["client_id"]))
elif args[:1] == ["--setup"]:
    os.makedirs(cfg, exist_ok=True)
    v = read_conf()
    cid = v.get("client_id") or input("OAuth client id: ").strip()
    csec = v.get("client_secret") or getpass.getpass("OAuth client secret (hidden): ").strip()
    v.update(client_id=cid, client_secret=csec)
    print("\nOpen this link, approve, then copy the FULL address of the page that fails to load:\n" + auth_url(cid) + "\n")
    v["token"] = exchange(v, extract_code(input("Paste the address (or just the code): ")))
    write_conf(v)
    ensure_env()
    print("Google Drive login saved. Next: sudo systemctl start backup.service")
elif len(args) == 1 and not args[0].startswith("--"):
    v = read_conf()
    if not v.get("client_id") or not v.get("client_secret"):
        sys.exit("no client configured (run --setup)")
    v["token"] = exchange(v, extract_code(args[0]))
    write_conf(v)
    ensure_env()
    print("Google Drive login refreshed. Next: sudo systemctl start backup.service")
else:
    sys.exit(__doc__ if __doc__ else "usage: gdrive-relogin.sh --setup | --print-url | '<address|code>'")
PY
)
exec python3 -c "$prog" "$cfg" "$@"
