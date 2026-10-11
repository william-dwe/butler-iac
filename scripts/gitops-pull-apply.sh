#!/usr/bin/env bash
# Pull this repo (butler-iac), then compose pull + up -d the root docker-compose.yml (includes manifests/*/compose.yml).
# Env: ~/.config/butler-iac/stack.env (ubuntu 0600; rendered by the butler Ansible role).
# Runs as ubuntu (docker group) from gitops-pull-apply.timer. Logs journald.
set -euo pipefail
repo=${GITOPS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
envfile=${STACK_ENV:-$HOME/.config/butler-iac/stack.env}

git -C "$repo" pull --ff-only
[ -r "$envfile" ] || { echo "missing $envfile (run butler role)" >&2; exit 1; }

compose=(docker compose --project-directory "$repo" --env-file "$envfile" -f "$repo/docker-compose.yml")
"${compose[@]}" pull
"${compose[@]}" up -d --remove-orphans
