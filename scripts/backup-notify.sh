#!/usr/bin/env bash
# Telegram alert when backup.service fails (backup.service has OnFailure=backup-notify.service). Runs as root.
# Sends through Hermes' own platform credentials with `hermes send` (no LLM involved, so it still works when the
# model is down). If the failure looks like a Google Drive login problem, the message includes the OAuth relogin
# link and the exact command to finish it (scripts/gdrive-relogin.sh).
set -euo pipefail

cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
infra=${INFRA_DIR:-/home/ubuntu/services/butler-iac}
profile=${HERMES_PROFILE:-orchestrator}
target=${HERMES_TARGET:-telegram}
container=${HERMES_CONTAINER:-hermes-gateway}
subject=${BACKUP_NOTIFY_SUBJECT:-[backup FAILED] $(hostname)}
log=${BACKUP_NOTIFY_LOG:-$(journalctl -u backup.service -n 80 --no-pager -o cat 2>/dev/null || true)}

# Last error-ish lines, with anything token-shaped masked and each line capped.
excerpt=$(printf '%s\n' "$log" | grep -vE '^\s*$' | tail -10 | sed -E 's/[A-Za-z0-9_\/+=.~-]{32,}/[redacted]/g' | cut -c1-180)

msg="The nightly backup did not complete.
Check: journalctl -u backup.service
Last log lines:
$excerpt"

# Google Drive auth problems: attach the relogin link (client_id is public; no secret is placed in the message).
if grep -qiE 'invalid_grant|token has been expired|expired or revoked|couldn.t fetch token|invalid_client|unauthorized_client|oauth2:' <<<"$log" \
   && [ -r "$cfg/rclone.conf" ]; then
  cid=$(sed -n 's/^client_id *= *//p' "$cfg/rclone.conf" | head -1)
  if [ -n "$cid" ]; then
    url=$("$infra/scripts/gdrive-relogin.sh" --print-url)
    msg="$msg

Google Drive login looks expired or revoked. To re-authorize:
1) Open this link and approve (it will end on a 'site can't be reached' page; that is expected):
$url
2) Copy the full address from the browser's address bar (http://127.0.0.1:53682/?code=...).
3) On the VPS run:  sudo $infra/scripts/gdrive-relogin.sh '<paste address here>'
Then: sudo systemctl start backup.service"
  fi
fi

msg=$(printf '%s' "$msg" | head -c 3800)
[ -z "${BACKUP_NOTIFY_DRY:-}" ] || { printf 'SUBJECT: %s\n%s\n' "$subject" "$msg"; exit 0; }
printf '%s\n' "$msg" | docker exec -i -u hermes "$container" hermes -p "$profile" send --to "$target" -s "$subject" -f - >/dev/null
echo "alert sent via hermes ($profile -> $target)"
