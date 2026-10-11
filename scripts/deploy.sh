#!/usr/bin/env bash
# Link systemd units and run the dashboard as ONE user (only one can own :9119).
# Usage: ./scripts/deploy.sh [hermes|ubuntu]   # default: last choice, else hermes
set -euo pipefail
cd "$(dirname "$0")/.."

user=${1:-$(cat .dashboard-user 2>/dev/null || echo agentops)}
id "$user" &>/dev/null || { echo "No such user: $user" >&2; exit 1; }
docker ps -q --filter name='^hermes-dashboard$' 2>/dev/null | grep -q . && { echo "hermes-dashboard container owns :9119; stop it first (bare-systemd deploy)." >&2; exit 1; }
sudo test -x "/home/$user/.local/bin/hermes" || { echo "Hermes not installed for $user" >&2; exit 1; }
echo "$user" > .dashboard-user

for unit in "$PWD"/systemd/*.service "$PWD"/systemd/*.timer; do
  sudo systemctl link "$unit"       # symlink -> /etc/systemd/system/
done
sudo systemctl daemon-reload

# Stop every other dashboard instance before starting the chosen one.
for other in $(systemctl list-units 'hermes-dashboard@*' --all --plain --no-legend | awk '{print $1}'); do
  [ "$other" = "hermes-dashboard@$user.service" ] || sudo systemctl disable --now "$other"
done

sudo systemctl enable "hermes-dashboard@$user"
sudo systemctl restart "hermes-dashboard@$user"
sudo systemctl enable "hermes-gateway@$user"
sudo systemctl restart "hermes-gateway@$user"
sudo systemctl enable --now gitops-pull-apply.timer
systemctl --no-pager --lines=5 status "hermes-dashboard@$user" || true
