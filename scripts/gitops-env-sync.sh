#!/usr/bin/env bash
# Root step run before gitops-pull-apply (ExecStartPre=+), after the checkout was pulled. Keeps the root-owned pieces in step
# with git so nothing needs a manual `sudo`. Each step is gated on a hash stamp in the control dir; all are no-ops when nothing changed.
#   1. .env changed                      -> dotenv-env.sh render (runtime.env) and stack-env.sh (stack.env)
#   2. stack.env inputs changed          -> stack-env.sh. Inputs = .env, stack-env.sh, and the compose ${VAR} list, so a new compose
#                                           variable reaches stack.env without an allowlist edit
#   3. systemd/*.service|timer changed   -> systemctl daemon-reload (the units are symlinks into this checkout)
#   4. env-set-api code/unit changed     -> systemctl try-restart env-set-api (a running service keeps its old code otherwise)
# Never prints secrets. ponytail: a Tailscale IP/hostname change still needs a manual `dotenv-env.sh render`.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
root=${GITOPS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
sum() { sha256sum | cut -d' ' -f1; }
stamped() { # $1 stamp file, $2 wanted value: true when already applied
  [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]
}
umask 077

env_hash=$(sum <"$root/.env")
changed=
if ! stamped "$cfg/.env-sync.sha256" "$env_hash" || [ ! -f "$cfg/runtime.env" ]; then
  "$root/scripts/dotenv-env.sh" render
  printf '%s\n' "$env_hash" >"$cfg/.env-sync.sha256"
  changed="$changed .env"
fi

stack_hash=$({ printf '%s\n' "$env_hash"; sum <"$root/scripts/stack-env.sh"; "$root/scripts/compose-vars.sh"; } | sum)
if ! stamped "$cfg/.stack-env-sync.sha256" "$stack_hash" || [ ! -f "$cfg/stack.env" ]; then
  "$root/scripts/stack-env.sh"
  printf '%s\n' "$stack_hash" >"$cfg/.stack-env-sync.sha256"
  changed="$changed stack.env"
fi

units_hash=$(cat "$root"/systemd/*.service "$root"/systemd/*.timer | sum)
if ! stamped "$cfg/.units-sync.sha256" "$units_hash"; then
  systemctl daemon-reload
  printf '%s\n' "$units_hash" >"$cfg/.units-sync.sha256"
  changed="$changed units"
fi

api_hash=$(cat "$root/scripts/env-set-api.py" "$root/systemd/env-set-api.service" "$root/scripts/git-sync.sh" | sum)
if ! stamped "$cfg/.env-set-api-sync.sha256" "$api_hash"; then
  systemctl try-restart env-set-api.service || echo "warn: env-set-api restart failed" >&2
  printf '%s\n' "$api_hash" >"$cfg/.env-set-api-sync.sha256"
  changed="$changed env-set-api"
fi

[ -z "$changed" ] || echo "synced:$changed"
