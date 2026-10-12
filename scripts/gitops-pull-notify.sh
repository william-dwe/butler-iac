#!/usr/bin/env bash
# Telegram alert when gitops-pull-apply.service fails (it has OnFailure=gitops-pull-notify.service). Runs as ubuntu (docker group).
# With `success <summary-file>` (called by gitops-pull-apply.sh after a deploy that changed something, or recovered from
# a failure) it sends a success message instead and clears the failure throttle state.
# Sends through Hermes with `hermes send` (no LLM involved). Failed applies retry every 5 minutes, so a persistent failure is
# throttled: the same error is re-sent at most once per GITOPS_NOTIFY_REPEAT seconds (default 3600); a new error sends at once.
set -euo pipefail

mode=${1:-fail}
summary_file=${2:-}
profile=${HERMES_PROFILE:-orchestrator}
target=${HERMES_TARGET:-telegram}
container=${HERMES_CONTAINER:-hermes-gateway}
repeat=${GITOPS_NOTIFY_REPEAT:-3600}
state=${GITOPS_NOTIFY_STATE:-$HOME/.local/state/butler-iac/gitops-pull-notify}
fence='```'

send() { # $1 subject, $2 body
  [ -z "${GITOPS_NOTIFY_DRY:-}" ] || { printf 'SUBJECT: %s\n%s\n' "$1" "$2"; return 1; }
  printf '%s\n' "$2" | docker exec -i -u hermes "$container" hermes -p "$profile" send --to "$target" -s "$1" -f - >/dev/null
}

if [ "$mode" = success ]; then
  subject=${GITOPS_NOTIFY_SUBJECT:-✅ GitOps deploy succeeded · $(hostname)}
  details=$(cat "$summary_file" 2>/dev/null || true)
  msg=$(printf 'butler-iac was pulled and applied.\n\n%s\n%s\n%s' "$fence" "${details//$fence/\'\'\'}" "$fence" | head -c 3800)
  if send "$subject" "$msg"; then
    rm -f "$state"
    echo "success alert sent via hermes ($profile -> $target)"
  fi
  exit 0
fi

subject=${GITOPS_NOTIFY_SUBJECT:-🚨 GitOps deploy FAILED · $(hostname)}
log=${GITOPS_NOTIFY_LOG:-$(journalctl -u gitops-pull-apply.service -n 40 --no-pager -o cat 2>/dev/null || true)}

# Last log lines, with anything token-shaped masked and each line capped.
excerpt=$(printf '%s\n' "$log" | grep -vE '^\s*$' | tail -10 | sed -E 's/[A-Za-z0-9_\/+=.~-]{32,}/[redacted]/g' | cut -c1-180)

sig=$(printf '%s' "$excerpt" | sha256sum | cut -d' ' -f1)
now=$(date +%s)
if [ -r "$state" ] && read -r last_sig last_ts <"$state" && [ "$last_sig" = "$sig" ] && [ $((now - last_ts)) -lt "$repeat" ]; then
  echo "same failure already alerted $((now - last_ts))s ago; skipping"
  exit 0
fi

msg=$(printf 'The butler-iac pull/apply did not complete. It retries every 5 min; the same error is re-sent at most hourly.\n\nLogs (last 10 lines):\n%s\n%s\n%s\nFull log: `journalctl -u gitops-pull-apply.service`' \
  "$fence" "${excerpt//$fence/\'\'\'}" "$fence" | head -c 3800)

if send "$subject" "$msg"; then
  mkdir -p "$(dirname "$state")"
  printf '%s %s\n' "$sig" "$now" >"$state"
  echo "alert sent via hermes ($profile -> $target)"
fi
