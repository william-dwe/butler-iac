#!/usr/bin/env bash
# Pull this repo (butler-iac), then compose pull + up -d the root docker-compose.yml (includes manifests/*/compose.yml).
# Env: ~/.config/butler-iac/stack.env (ubuntu 0600; rendered by the butler Ansible role).
# Runs as ubuntu (docker group) from gitops-pull-apply.timer (every minute). Logs journald.
# Cheap gate first: each run only does `git fetch`; the full apply (compose pull + up -d) runs when the repo has new
# commits, or when HEAD differs from the revision of the last full run (local commits), or when the last full run is older than GITOPS_FULL_INTERVAL (default 1800s, catches updated image tags), or
# GITOPS_RETRY_INTERVAL (default 300s) after a failed full run. GITOPS_FORCE=1 skips the gate. Gated runs are silent.
set -euo pipefail
repo=${GITOPS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
envfile=${STACK_ENV:-$HOME/.config/butler-iac/stack.env}
stamp=${GITOPS_STAMP:-$HOME/.local/state/butler-iac/gitops-last-full}
full_interval=${GITOPS_FULL_INTERVAL:-1800}
retry_interval=${GITOPS_RETRY_INTERVAL:-300}

git -C "$repo" fetch --quiet
behind=$(git -C "$repo" rev-list --count 'HEAD..@{u}')
last_ts=0 last_status=ok last_rev=
[ ! -r "$stamp" ] || read -r last_ts last_status last_rev <"$stamp" || true
age=$(( $(date +%s) - last_ts ))
interval=$full_interval
[ "$last_status" = ok ] || interval=$retry_interval
if [ -z "${GITOPS_FORCE:-}" ] && [ "$behind" -eq 0 ] && [ "$last_rev" = "$(git -C "$repo" rev-parse --short HEAD)" ] && [ "$age" -lt "$interval" ]; then exit 0; fi
echo "full apply: behind=$behind last_full=${age}s ago ($last_status)"
mkdir -p "$(dirname "$stamp")"
trap 'rc=$?; printf "%s %s %s\n" "$(date +%s)" "$([ $rc -eq 0 ] && echo ok || echo fail)" "$(git -C "$repo" rev-parse --short HEAD)" >"$stamp"' EXIT

# Deploy fingerprint (containers + their image IDs) before/after, to alert only when a run changed something.
state=${GITOPS_NOTIFY_STATE:-$HOME/.local/state/butler-iac/gitops-pull-notify}
snap() { docker ps -a --filter "label=com.docker.compose.project" --format '{{.Names}} {{.ID}} {{.Image}}' | sort; }
before_rev=$(git -C "$repo" rev-parse --short HEAD)
before=$(snap || true)

"$repo/scripts/git-sync.sh" --push-env
[ -r "$envfile" ] || { echo "missing $envfile (run butler role)" >&2; exit 1; }

compose=(docker compose --project-directory "$repo" --env-file "$envfile" -f "$repo/docker-compose.yml")
"${compose[@]}" pull
"${compose[@]}" up -d --remove-orphans

# Success alert: only if the run changed the repo or the containers, or it recovers from an alerted failure ($state exists).
after_rev=$(git -C "$repo" rev-parse --short HEAD)
after=$(snap || true)
if [ "$before_rev" != "$after_rev" ] || [ "$before" != "$after" ] || [ -e "$state" ]; then
  summary=$(mktemp)
  {
    [ "$before_rev" = "$after_rev" ] && echo "Repo: $after_rev (unchanged)" || echo "Repo: $before_rev -> $after_rev: $(git -C "$repo" log -1 --format=%s)"
    changed=$(diff <(echo "$before") <(echo "$after") | sed -n 's/^> \([^ ]*\) [^ ]* \(.*\)$/\1 (\2)/p' | head -15 || true)
    [ -z "$changed" ] || printf 'Updated/recreated containers:\n%s\n' "$changed"
    [ ! -e "$state" ] || echo "Recovered from an earlier failure."
  } >"$summary"
  "$repo/scripts/gitops-pull-notify.sh" success "$summary" || echo "warn: success alert failed" >&2
  rm -f "$summary"
fi
