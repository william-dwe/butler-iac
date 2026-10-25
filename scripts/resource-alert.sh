#!/usr/bin/env bash
# Telegram alert when disk (/) or memory use reaches RESOURCE_ALERT_PCT (default 90). Runs as ubuntu (docker group) from
# resource-alert.timer every 5 minutes. Sends through Hermes with `hermes send` (no LLM involved).
# Memory use = 100 - MemAvailable/MemTotal, so reclaimable page cache does not count. A metric that stays over the
# threshold is re-sent at most every RESOURCE_ALERT_REPEAT seconds (default 3h); a "recovered" message follows once it
# drops below RESOURCE_ALERT_CLEAR_PCT (default 85), so a value hovering around 90 does not flap.
set -euo pipefail

pct=${RESOURCE_ALERT_PCT:-90}
clear=${RESOURCE_ALERT_CLEAR_PCT:-85}
repeat=${RESOURCE_ALERT_REPEAT:-10800}
profile=${HERMES_PROFILE:-orchestrator}
target=${HERMES_TARGET:-telegram}
container=${HERMES_CONTAINER:-hermes-gateway}
state_dir=${RESOURCE_ALERT_STATE:-$HOME/.local/state/butler-iac/resource-alert}
mkdir -p "$state_dir"
fence='```'

send() { # $1 subject, $2 body
  [ -z "${RESOURCE_ALERT_DRY:-}" ] || { printf 'SUBJECT: %s\n%s\n' "$1" "$2"; return 0; }
  # ponytail: 60s cap; a swapping host can hang docker exec, and the next tick retries because state is written only after a send.
  printf '%s\n' "$2" | timeout 60 docker exec -i -u hermes "$container" hermes -p "$profile" send --to "$target" -s "$1" -f - >/dev/null
}

detail() { # $1 metric
  case $1 in
    disk) df -h / | tail -1 | awk '{printf "/ %s used of %s, %s free\n", $3, $2, $4}' ;;
    mem)  free -m | awk '/^Mem:/{printf "RAM %d MB used of %d MB, %d MB available\n", $3, $2, $7} /^Swap:/{printf "Swap %d MB used of %d MB\n", $3, $2}'
          echo "Top by RSS:"; ps -eo rss=,comm= --sort=-rss | head -5 | awk '{printf "  %d MB %s\n", $1/1024, $2}' ;;
  esac
}

now=$(date +%s)
for metric in disk mem; do
  case $metric in
    disk) value=$(df --output=pcent / | tail -1 | tr -dc 0-9); label="Disk" ;;
    mem)  value=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo); label="Memory" ;;
  esac
  state=$state_dir/$metric
  host=$(hostname)

  if [ "$value" -ge "$pct" ]; then
    if [ -r "$state" ] && [ $((now - $(cat "$state"))) -lt "$repeat" ]; then
      echo "$metric ${value}% still over ${pct}%, alerted $((now - $(cat "$state")))s ago; skipping"
      continue
    fi
    msg=$(printf '%s is at %s%% (threshold %s%%).\n\n%s\n%s\n%s' "$label" "$value" "$pct" "$fence" "$(detail "$metric")" "$fence" | head -c 3800)
    send "⚠️ $label ${value}% · $host" "$msg" && echo "$now" >"$state" && echo "$metric alert sent (${value}%)"
  elif [ "$value" -lt "$clear" ] && [ -e "$state" ]; then
    send "✅ $label back to ${value}% · $host" "$label is at ${value}% again (below ${clear}%)." && rm -f "$state" && echo "$metric recovery sent (${value}%)"
  fi
done
