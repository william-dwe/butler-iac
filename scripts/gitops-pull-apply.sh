#!/usr/bin/env bash
# Pull this repo (butler-iac), then compose pull + up -d the root docker-compose.yml (includes manifests/*/compose.yml).
# Env: ~/.config/butler-iac/stack.env (ubuntu 0600; rendered by the butler Ansible role).
# Runs as ubuntu (docker group) from gitops-pull-apply.timer. Logs journald.
set -euo pipefail
repo=${GITOPS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
envfile=${STACK_ENV:-$HOME/.config/butler-iac/stack.env}

# Deploy fingerprint (containers + their image IDs) before/after, to alert only when a run changed something.
state=${GITOPS_NOTIFY_STATE:-$HOME/.local/state/butler-iac/gitops-pull-notify}
snap() { docker ps -a --filter "label=com.docker.compose.project" --format '{{.Names}} {{.ID}} {{.Image}}' | sort; }
before_rev=$(git -C "$repo" rev-parse --short HEAD)
before=$(snap || true)

git -C "$repo" pull --ff-only
[ -r "$envfile" ] || { echo "missing $envfile (run butler role)" >&2; exit 1; }

compose=(docker compose --project-directory "$repo" --env-file "$envfile" -f "$repo/docker-compose.yml")
"${compose[@]}" pull
"${compose[@]}" up -d --remove-orphans

# Tailnet-only HTTPS :443 -> hermes-webui (loopback). Idempotent; never Funnel. Mirrors ansible/roles/hermes/tasks/webui_serve.yml.
# ponytail: needs ubuntu allowed to manage Tailscale Serve (operator); on failure it warns and leaves the compose apply green.
target=http://127.0.0.1:8787
if [ "$(docker inspect -f '{{.State.Running}}' hermes-webui 2>/dev/null)" = true ]; then
  status=$(tailscale serve status 2>&1 || true)
  if [[ $status == *"$target"* ]]; then :
  elif grep -qE '^https://[^:[:space:]]+[[:space:]]' <<<"$status"; then
    echo "warn: HTTPS :443 Serve route already in use; not overwriting" >&2
  else
    tailscale serve --bg --https=443 "$target" || echo "warn: tailscale serve failed (is ubuntu the Tailscale operator?)" >&2
  fi
fi

# Success alert: only if the run changed the repo or the containers, or it recovers from an alerted failure ($state exists).
after_rev=$(git -C "$repo" rev-parse --short HEAD)
after=$(snap || true)
if [ "$before_rev" != "$after_rev" ] || [ "$before" != "$after" ] || [ -e "$state" ]; then
  summary=$(mktemp)
  {
    [ "$before_rev" = "$after_rev" ] && echo "Repo: $after_rev (unchanged)" || echo "Repo: $before_rev -> $after_rev: $(git -C "$repo" log -1 --format=%s)"
    changed=$(diff <(echo "$before") <(echo "$after") | sed -n 's/^> \([^ ]*\) [^ ]* \(.*\)$/\1 (\2)/p' | head -15)
    [ -z "$changed" ] || printf 'Updated/recreated containers:\n%s\n' "$changed"
    [ ! -e "$state" ] || echo "Recovered from an earlier failure."
  } >"$summary"
  "$repo/scripts/gitops-pull-notify.sh" success "$summary" || echo "warn: success alert failed" >&2
  rm -f "$summary"
fi
