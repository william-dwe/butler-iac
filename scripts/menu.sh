#!/usr/bin/env bash
# VPS control panel (whiptail TUI): status, dashboard controls, Hermes sudo. Initialize via ansible/playbooks/init.yml, then deploy services via ansible/playbooks/services.yml.
# Usage: ./scripts/menu.sh
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -uo pipefail
cd "$(dirname "$0")/.."
if ! command -v whiptail &>/dev/null; then
  echo "Installing whiptail for VPS setup..."
  sudo apt-get update && sudo apt-get install -y whiptail || { echo "whiptail install failed." >&2; exit 1; }
fi

TITLE="VPS control panel"
pause() { read -rp $'\nPress Enter to return to the menu...' _; }

status_text() {
  local user note="" unit active holder ip router headroom
  user=$(cat .dashboard-user 2>/dev/null) || { user=agentops; note=undeployed; }
  unit="hermes-dashboard@$user"
  active=$(systemctl list-units 'hermes-dashboard@*' --state=active --plain --no-legend | awk '{print $1}' | xargs)
  holder=$(ps -eo user=,args= | awk '/hermes dashboard/ && /9119/ && !/awk/ {print $1; exit}')
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  # ponytail: no docker group yet (needs re-login after bootstrap) reads as "unknown"; sudo would prompt inside the TUI.
  router=$(docker inspect -f '{{.State.Status}}' 9router 2>/dev/null) || router="unknown (not created / no docker access)"
  headroom=$(docker inspect -f '{{.State.Status}}' headroom 2>/dev/null) || headroom="unknown (not created / no docker access)"

  # Session groups (id -Gn) vs. account groups (id -Gn $me): differ right after usermod, until re-login.
  local me groups relogin=""
  me=$(id -un)
  groups=$(id -Gn | tr ' ' '\n' | grep -xE 'sudo|docker|agentops' | xargs)
  id -Gn "$me" | grep -qw docker && ! id -Gn | grep -qw docker && relogin=" (re-login for docker)"

  section() { printf '[ %s ]\n' "$1"; }
  row() { printf '  %-17s%s\n' "$@"; }

  section "Session"
  row "Current User:"    "$me" \
      "Groups:"          "${groups:-none}$relogin" \
      "Connected From:"  "$([ -n "${SSH_CONNECTION:-}" ] && echo "ssh ${SSH_CONNECTION%% *}" || echo local)"
  section "Host"
  row "Hostname:"        "$(hostname) (up $(uptime -p | sed 's/^up //'))" \
      "Resources:"       "load $(cut -d' ' -f1 /proc/loadavg) | disk / $(df -h --output=pcent / | tail -1 | xargs) | mem $(free -h | awk '/^Mem/{print $3"/"$2}')"
  section "Tailscale"
  row "IP:"              "${ip:-not connected}"
  section "Hermes Dashboard"
  row "Configured User:" "$([ -n "$note" ] && echo "not deployed yet (default: $user)" || echo "$user")" \
      "Service Name:"    "$unit" \
      "URL:"             "http://${ip:-<no tailscale ip>}:9119"
  if [ -n "$holder" ] && [ -z "$active" ]; then
    row "[ ! ] Warning" "manual (non-systemd) run as $holder holds :9119;" "" "stop it before deploying."
  elif [ -n "$active" ] && [ "$active" != "$unit.service" ]; then
    row "[ ! ] Warning" "running $active differs from configured user;" "" "use \"Switch dashboard user\"."
  fi
  section "9router (docker)"
  row "Container:"       "$router" \
      "URL:"             "http://${ip:-<no tailscale ip>}:20128"
  section "Headroom (docker)"
  row "Container:"       "$headroom" \
      "URL:"             "http://headroom:8787 (Docker-internal only)"
}

pick_user() {
  local cur; cur=$(cat .dashboard-user 2>/dev/null || echo agentops)
  whiptail --title "$TITLE" --radiolist "Run the dashboard as (space to select):" 12 60 2 \
    hermes "dedicated non-root user" "$([ "$cur" = hermes ] && echo ON || echo OFF)" \
    ubuntu "admin user"              "$([ "$cur" = ubuntu ] && echo ON || echo OFF)" \
    3>&1 1>&2 2>&3
}

switch_user() {
  local user; user=$(pick_user) || return
  whiptail --title "$TITLE" --yesno "Switch dashboard to '$user'?\n\nThe dashboard restarts: open browser sessions (including an agent chat running inside it) will disconnect." 12 64 || return
  clear; ./scripts/deploy.sh "$user"; pause
}

toggle_hermes_sudo() {
  local f=/etc/sudoers.d/90-hermes-agent action msg
  clear; echo "Checking hermes sudo grant (your sudo password may be asked)..."
  if sudo test -f "$f"; then
    action=off; msg="REVOKE hermes passwordless sudo?\n\nRemoves $f. hermes' sudo group membership and Docker access are NOT changed."
  else
    action=on;  msg="GRANT hermes passwordless sudo?\n\nhermes (and every agent running as hermes) gets unrestricted root without a password."
  fi
  whiptail --title "$TITLE" --yesno "$msg" 12 70 || return
  clear; sudo ./scripts/hermes-sudo.sh "$action"; pause
}

dashboard_menu() {
  local choice
  choice=$(whiptail --title "$TITLE" --menu "Dashboard controls" 14 64 3 \
    1 "Switch dashboard user" \
    2 "Restart dashboard" \
    3 "Follow dashboard logs" \
    b "Back" 3>&1 1>&2 2>&3) || return
  local user; user=$(cat .dashboard-user 2>/dev/null || echo agentops)
  case $choice in
    1) switch_user ;;
    2) clear; sudo systemctl restart "hermes-dashboard@$user" && echo restarted; pause ;;
    3) clear; journalctl -u "hermes-dashboard@$user" -n 50 -f; pause ;;
  esac
}

while true; do
  status=$(status_text)
  # ponytail: capped at terminal height; on very short terminals the header gets clipped.
  h=$(( $(wc -l <<<"$status") + 9 )); rows=$(tput lines 2>/dev/null || echo 24); (( h > rows )) && h=$rows
  choice=$(whiptail --title "$TITLE" --menu "$status" "$h" 76 3 \
    1 "Dashboard controls" \
    2 "Hermes sudo access" \
    q "Quit" 3>&1 1>&2 2>&3) || break
  case $choice in
    1) dashboard_menu ;;
    2) toggle_hermes_sudo ;;
    q) break ;;
  esac
done
clear
