#!/usr/bin/env bash
# Put the backup secrets into Ansible Vault so a rebuilt host can recover them. Run as ubuntu (administrator action).
#   scripts/vault-seed-backup.sh [--dry-run] [--yes] [--commit]
# Reads (via sudo, never printed):  backup.pass                    -> vault_backup_password
#                                   rclone.conf [gdrive] client_id -> vault_gdrive_client_id
#                                   rclone.conf [gdrive] client_secret -> vault_gdrive_client_secret
# Upserts those keys in ansible/group_vars/all/vault.yml with `ansible-vault edit` (other keys untouched, re-running
# is idempotent), then re-reads the vault to prove every value matches. --commit makes a local commit (no push).
# The token (vault_gdrive_token) is deliberately not stored: a fresh login makes a new one.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
vault=${VAULT_FILE:-$repo/ansible/group_vars/all/vault.yml}
dry=0 yes=0 commit=0
for a in "$@"; do
  case $a in --dry-run) dry=1 ;; --yes) yes=1 ;; --commit) commit=1 ;; *) echo "usage: $0 [--dry-run] [--yes] [--commit]" >&2; exit 2 ;; esac
done
[ "$EUID" -ne 0 ] || { echo "run as ubuntu, not root (ansible-vault uses ansible/ansible.cfg)" >&2; exit 1; }
command -v ansible-vault >/dev/null || { echo "ansible-vault not found" >&2; exit 1; }
[ -f "$vault" ] || { echo "missing $vault" >&2; exit 1; }

# Values stay in the environment of this process tree only (never in argv, never echoed).
SEED_BACKUP_PASSWORD=$(sudo cat "$cfg/backup.pass") || { echo "cannot read $cfg/backup.pass" >&2; exit 1; }
[ -n "$SEED_BACKUP_PASSWORD" ] || { echo "backup.pass is empty" >&2; exit 1; }
conf=$(sudo cat "$cfg/rclone.conf" 2>/dev/null || true)
SEED_GDRIVE_CLIENT_ID=$(printf '%s\n' "$conf" | sed -n '/^\[gdrive\]/,/^\[/{s/^client_id *= *//p}' | head -1)
SEED_GDRIVE_CLIENT_SECRET=$(printf '%s\n' "$conf" | sed -n '/^\[gdrive\]/,/^\[/{s/^client_secret *= *//p}' | head -1)
unset conf
export SEED_BACKUP_PASSWORD SEED_GDRIVE_CLIENT_ID SEED_GDRIVE_CLIENT_SECRET
[ -n "$SEED_GDRIVE_CLIENT_ID" ] && [ -n "$SEED_GDRIVE_CLIENT_SECRET" ] || echo "note: no Drive client in rclone.conf yet; only the backup password will be stored"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Shared logic: compare / upsert. Keys map to environment variables.
cat > "$tmp/seed.py" <<'PY'
import json, os, re, sys
KEYS = {
    "vault_backup_password": "SEED_BACKUP_PASSWORD",
    "vault_gdrive_client_id": "SEED_GDRIVE_CLIENT_ID",
    "vault_gdrive_client_secret": "SEED_GDRIVE_CLIENT_SECRET",
}
want = {k: os.environ[v] for k, v in KEYS.items() if os.environ.get(v)}

def parse(text):
    cur = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$", line)
        if m and m.group(1) in KEYS:
            raw = m.group(2).strip()
            if raw.startswith('"'):
                cur[m.group(1)] = json.loads(raw)
            elif raw.startswith("'"):
                cur[m.group(1)] = raw[1:-1].replace("''", "'")
            else:
                cur[m.group(1)] = raw
    return cur

def status(text):
    cur = parse(text)
    return {k: ("missing" if k not in cur else "same" if cur[k] == v else "differs") for k, v in want.items()}

def upsert(text):
    lines = text.splitlines()
    for k, v in want.items():
        new = f"{k}: {json.dumps(v)}"   # JSON string == valid YAML double-quoted scalar
        for i, line in enumerate(lines):
            if re.match(rf"^{re.escape(k)}\s*:", line):
                lines[i] = new
                break
        else:
            lines.append(new)
    return "\n".join(lines) + "\n"

mode = sys.argv[1]
if mode == "status":                     # stdin: decrypted vault -> "key state" lines
    for k, s in status(sys.stdin.read()).items():
        print(k, s)
elif mode == "edit":                     # argv[2]: the temp file ansible-vault hands to $EDITOR
    p = sys.argv[2]
    t = open(p).read()
    open(p, "w").write(upsert(t))
    import yaml  # fail loudly if the result is not valid YAML
    yaml.safe_load(open(p))
PY
printf '#!/bin/sh\nexec python3 "%s/seed.py" edit "$@"\n' "$tmp" > "$tmp/editor.sh"; chmod +x "$tmp/editor.sh"

report() {  # prints "key state" per wanted key from the decrypted vault
  (cd "$repo/ansible" && ansible-vault view "$vault") | python3 "$tmp/seed.py" status
}

echo "== vault status (no values shown)"
before=$(report); printf '%s\n' "$before" | sed 's/^/  /'
if ! printf '%s\n' "$before" | grep -qE ' (missing|differs)$'; then echo "nothing to do: vault already matches the host"; exit 0; fi
[ "$dry" = 0 ] || { echo "--dry-run: no changes made"; exit 0; }

if [ "$yes" = 0 ]; then
  read -r -p "Update the keys above in $(basename "$vault")? [y/N] " ans
  [ "$ans" = y ] || [ "$ans" = Y ] || { echo "aborted"; exit 1; }
fi

(cd "$repo/ansible" && EDITOR="$tmp/editor.sh" ansible-vault edit "$vault")

echo "== verify (re-read the vault, compare with the host)"
after=$(report); printf '%s\n' "$after" | sed 's/^/  /'
if printf '%s\n' "$after" | grep -qE ' (missing|differs)$'; then echo "VERIFY FAILED" >&2; exit 1; fi

git -C "$repo" diff --stat -- "$vault" 2>/dev/null | tail -2 || true
if [ "$commit" = 1 ]; then
  git -C "$repo" add "$vault"
  git -C "$repo" -c user.name=Ubuntu -c user.email=ubuntu@localhost.localdomain commit -q -m "vault: store backup password and Drive client for disaster recovery"
  echo "committed locally (not pushed): $(git -C "$repo" log --oneline -1)"
else
  echo "not committed. Review, then: git add ansible/group_vars/all/vault.yml && git commit && git push"
fi
echo "done. Re-apply: cd ansible && ansible-playbook playbooks/services.yml --tags backup"
