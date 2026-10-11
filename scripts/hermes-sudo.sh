#!/usr/bin/env bash
# Usage: sudo ./scripts/hermes-sudo.sh on|off|status
# on grants unrestricted passwordless root access. off removes ONLY this grant;
# it does not revoke Docker access or sudo permissions granted elsewhere.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
file=/etc/sudoers.d/90-hermes-agent
case ${1:-} in
  on|off|status) [ "$#" -eq 1 ] || { echo 'Expected one argument' >&2; exit 2; } ;;
  *) echo "Usage: sudo $0 on|off|status" >&2; exit 2 ;;
esac
[ "$EUID" -eq 0 ] || { echo 'Run this script with sudo from your ubuntu terminal.' >&2; exit 1; }
case $1 in
  on)
    id agentops >/dev/null
    visudo -c >/dev/null
    [ -d /etc/sudoers.d ] || { echo '/etc/sudoers.d is missing' >&2; exit 1; }
    # A dot keeps the temporary file out of sudoers includedir processing.
    tmp=$(mktemp /etc/sudoers.d/.hermes-agent.XXXXXXXX)
    trap 'rm -f -- "$tmp"' EXIT
    printf 'agentops ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$tmp"
    chown root:root "$tmp"
    chmod 0440 "$tmp"
    visudo -cf "$tmp" >/dev/null
    mv -fT -- "$tmp" "$file"
    echo 'Enabled: agentops has unrestricted passwordless sudo.'
    ;;
  off)
    rm -f -- "$file"
    echo 'Removed this passwordless sudo grant. Other grants and Docker access are unchanged.'
    ;;
  status)
    if [ -f "$file" ]; then
      echo "Grant present: $file"
      visudo -cf "$file"
    else
      echo 'This script’s sudo grant is absent.'
    fi
    ;;
esac
