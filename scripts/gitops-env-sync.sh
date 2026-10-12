#!/usr/bin/env bash
# Root step run before gitops-pull-apply (ExecStartPre=+): when the committed .env changed, re-render the root-only
# runtime.env and the allowlisted stack.env. Never prints secrets. ponytail: change detection is the .env hash only, so a
# Tailscale IP/hostname change still needs a manual `dotenv-env.sh render`.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
stamp=$cfg/.env-sync.sha256
want=$(sha256sum "$root/.env" | cut -d' ' -f1)
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] && [ -f "$cfg/runtime.env" ] && [ -f "$cfg/stack.env" ]; then exit 0; fi
"$root/scripts/dotenv-env.sh" render
"$root/scripts/stack-env.sh"
umask 077
printf '%s\n' "$want" >"$stamp"
echo "env synced (.env ${want:0:12})"
