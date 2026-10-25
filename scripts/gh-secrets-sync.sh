#!/usr/bin/env bash
# Push the butler-iac bump app credentials from Ansible Vault to GitHub Actions secrets of service repos.
# Run as ubuntu (administrator action):  scripts/gh-secrets-sync.sh [--dry-run] [owner/repo ...]   (default: william-dwe/butler)
# Reads vault_butler_iac_app_id / vault_butler_iac_app_key from ansible/group_vars/all/vault.yml and sets
# BUTLER_IAC_APP_ID / BUTLER_IAC_APP_KEY with `gh secret set` (value piped on stdin, never in argv, never printed).
# Seed the vault first (multi-line PEM, so use a block scalar):  cd ansible && ansible-vault edit group_vars/all/vault.yml
#   vault_butler_iac_app_id: "123456"
#   vault_butler_iac_app_key: |
#     -----BEGIN RSA PRIVATE KEY-----
#     ...
# ponytail: sets the secrets unconditionally on every run (gh cannot read values back to compare).
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
vault=${VAULT_FILE:-$repo/ansible/group_vars/all/vault.yml}
dry=0
[ "${1:-}" != --dry-run ] || { dry=1; shift; }
repos=("$@"); [ ${#repos[@]} -gt 0 ] || repos=(william-dwe/butler)
[ "$EUID" -ne 0 ] || { echo "run as ubuntu, not root (ansible-vault uses ansible/ansible.cfg)" >&2; exit 1; }
for c in ansible-vault gh python3; do command -v "$c" >/dev/null || { echo "$c not found" >&2; exit 1; }; done
[ -f "$vault" ] || { echo "missing $vault" >&2; exit 1; }

# Prints one vault value to stdout, no trailing newline; fails if the key is absent or empty.
vget() {
  (cd "$repo/ansible" && ansible-vault view "$vault") | python3 -c '
import sys, yaml
v = (yaml.safe_load(sys.stdin) or {}).get(sys.argv[1])
if not v: sys.exit("vault key missing or empty: " + sys.argv[1])
sys.stdout.write(str(v).rstrip("\n"))' "$1"
}

# Fail before touching GitHub if either value is absent.
vget vault_butler_iac_app_id >/dev/null
vget vault_butler_iac_app_key >/dev/null
echo "vault OK: both values present (not shown)"

for r in "${repos[@]}"; do
  if [ "$dry" = 1 ]; then echo "--dry-run: would set BUTLER_IAC_APP_ID and BUTLER_IAC_APP_KEY on $r"; continue; fi
  vget vault_butler_iac_app_id  | gh secret set BUTLER_IAC_APP_ID  -R "$r"
  vget vault_butler_iac_app_key | gh secret set BUTLER_IAC_APP_KEY -R "$r"
done
