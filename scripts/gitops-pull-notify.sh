#!/usr/bin/env bash
# Telegram alert when gitops-pull-apply.service fails (it has OnFailure=gitops-pull-notify.service). Runs as ubuntu (docker group).
# With `success <summary-file>` (called by gitops-pull-apply.sh after a deploy that changed something, or recovered from
# a failure) it sends a success message instead and clears the failure throttle state.
# Sends through Hermes with `hermes send` (no LLM involved). The timer fires every 10 minutes, so a persistent failure is
# throttled: the same error is re-sent at most once per GITOPS_NOTIFY_REPEAT seconds (default 3600); a new error sends at once.
set -euo pipefail

mode=${1:-fail}
summary_file=${2:-}
profile=${HERMES_PROFILE:-orchestrator}
target=${HERMES_TARGET:-telegram}
container=${HERMES_CONTAINER:-hermes-gateway}
subject=${GITOPS_NOTIFY_SUBJECT:-[gitops pull FAILED] $(hostname)}
[ "$mode" != success ] || subject=${GITOPS_NOTIFY_SUBJECT:-[gitops deploy OK] $(hostname)}
repeat=${GITOPS_NOTIFY_REPEAT:-3600}
state=${GITOPS_NOTIFY_STATE:-$HOME/.local/state/butler-iac/gitops-pull-notify}
log=${GITOPS_NOTIFY_LOG:-$(journalctl -u gitops-pull-apply.service -n 40 --no-pager -o cat 2>/dev/null || true)}

if [ "$mode" = success ]; then
  msg=$(printf 'GitOps deploy succeeded.\n%s' "$(cat "$summary_file" 2>/dev/null)" | head -c 3800)
  if [ -z "${GITOPS_NOTIFY_DRY:-}" ]; then
    printf '%s\n' "$msg" | docker exec -i -u hermes "$container" hermes -p "$profile" send --to "$target" -s "$subject" -f - >/dev/null
    rm -f "$state"
    echo "success alert sent via hermes ($profile -> $target)"
  else
    printf 'SUBJECT: %s\n%s\n' "$subject" "$msg"
  fi
  exit 0
fi

# Last log lines, with anything token-shaped masked and each line capped.
excerpt=$(printf '%s\n' "$log" | grep -vE '^\s*$' | tail -10 | sed -E 's/[A-Za-z0-9_\/+=.~-]{32,}/[redacted]/g' | cut -c1-180)

sig=$(printf '%s' "$excerpt" | sha256sum | cut -d' ' -f1)
now=$(date +%s)
if [ -r "$state" ] && read -r last_sig last_ts <"$state" && [ "$last_sig" = "$sig" ] && [ $((now - last_ts)) -lt "$repeat" ]; then
  echo "same failure already alerted $((now - last_ts))s ago; skipping"
  exit 0
fi

msg="The GitOps pull/apply run failed (retries every 10 min; repeats of the same error are sent at most hourly).
Check: journalctl -u gitops-pull-apply.service
Last log lines:
$excerpt"
msg=$(printf '%s' "$msg" | head -c 3800)

[ -z "${GITOPS_NOTIFY_DRY:-}" ] || { printf 'SUBJECT: %s\n%s\n' "$subject" "$msg"; exit 0; }
printf '%s\n' "$msg" | docker exec -i -u hermes "$container" hermes -p "$profile" send --to "$target" -s "$subject" -f - >/dev/null
mkdir -p "$(dirname "$state")"
printf '%s %s\n' "$sig" "$now" >"$state"
echo "alert sent via hermes ($profile -> $target)"
