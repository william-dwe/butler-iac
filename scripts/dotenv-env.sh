#!/usr/bin/env bash
# Decrypt the committed, dotenvx-encrypted .env into the root-only runtime environment file.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
encrypted=$root/.env
# Control-plane files live with the admin user (ubuntu), outside the agents' home; keys + runtime.env stay root-owned 0600.
cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
keys=$cfg/dotenvx.keys
target=$cfg/runtime.env
helper=$root/scripts/dotenv-env.py

usage() {
  echo "Usage: $0 {render|status}" >&2
  exit 2
}

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
}

render() {
  local decrypted= rendered= ip host origin=
  require_root
  command -v dotenvx >/dev/null || { echo "dotenvx CLI missing." >&2; exit 1; }
  command -v tailscale >/dev/null || { echo "Tailscale CLI missing." >&2; exit 1; }
  command -v python3 >/dev/null || { echo "Python 3 missing." >&2; exit 1; }
  [ -f "$encrypted" ] && [ ! -L "$encrypted" ] || { echo "Encrypted .env missing." >&2; exit 1; }
  [ -f "$keys" ] && [ ! -L "$keys" ] || { echo "dotenvx private key file missing or invalid." >&2; exit 1; }
  [ "$(stat -c '%u:%g:%a' "$keys")" = 0:0:600 ] || { echo "dotenvx private key file has invalid ownership or permissions." >&2; exit 1; }
  umask 077
  decrypted=$(mktemp /etc/.personal-agent-infra.decrypt.XXXXXX)
  rendered=$(mktemp /etc/.personal-agent-infra.render.XXXXXX)
  trap 'rm -f -- "${decrypted:-}" "${rendered:-}"' EXIT
  if ! dotenvx decrypt -f "$encrypted" -fk "$keys" --stdout >"$decrypted" 2>/dev/null; then
    echo "dotenvx decrypt failed." >&2
    exit 1
  fi
  ip=$(tailscale ip -4 2>/dev/null | sed -n '1p')
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Tailscale has no IPv4 address." >&2; exit 1; }
  host=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"].get("DNSName", "").rstrip("."))') || { echo "Tailscale MagicDNS lookup failed." >&2; exit 1; }
  [[ $host == *.ts.net ]] || { echo "Tailscale MagicDNS name unavailable." >&2; exit 1; }
  origin=https://$host:8444
  "$helper" rewrite "$decrypted" "$rendered" "$ip" "$origin"
  chown root:root "$rendered"
  chmod 0600 "$rendered"
  mv -f "$rendered" "$target"
  rendered=
  echo "Rendered $target."
}

status_file() {
  local label=$1 path=$2
  if [ ! -e "$path" ] || [ -L "$path" ]; then
    printf '%s: missing\n' "$label"
  elif [ "$(stat -c '%u:%g:%a' "$path" 2>/dev/null)" = 0:0:600 ]; then
    printf '%s: configured\n' "$label"
  else
    printf '%s: invalid permissions\n' "$label"
  fi
}

status() {
  if command -v dotenvx >/dev/null; then echo "dotenvx CLI: installed"; else echo "dotenvx CLI: missing"; fi
  status_file 'dotenvx private key' "$keys"
  status_file 'Rendered runtime configuration' "$target"
  echo "Decryption: performed only during render"
}

[ $# -eq 1 ] || usage
case $1 in
  render) render ;;
  status) status ;;
  *) usage ;;
esac
