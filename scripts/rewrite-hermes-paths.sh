#!/usr/bin/env bash
# Phase 2 (docs/open-items.md): rewrite /home/hermes -> /home/agentops in agent data. Run as agentops.
# Dry-run by default (lists files); --apply backs up to tar.gz first, then rewrites in place.
# Skipped on purpose: upstream checkout, caches, sessions/logs/backups (history), installs, binary/db files,
# and the wiki (curated; edit SCHEMA.md via librarian + bin/data-commit after William approves).
set -euo pipefail
home=${AGENT_HOME:-/home/agentops}
targets=("$home/.hermes")
[[ -f $home/.paseo/config.json ]] && targets+=("$home/.paseo/config.json")

list=$(mktemp); trap 'rm -f "$list"' EXIT
grep -rIlZ '/home/hermes\b' "${targets[@]}" \
  --exclude-dir=hermes-agent --exclude-dir=node --exclude-dir=cache --exclude-dir=sessions \
  --exclude-dir=backups --exclude-dir=.curator_backups --exclude-dir=logs --exclude-dir=installs \
  --exclude-dir=image_cache --exclude-dir=audio_cache --exclude='*.db*' --exclude='.env*' \
  > "$list" || true

echo "files: $(tr -cd '\0' < "$list" | wc -c)"
tr '\0' '\n' < "$list"
[[ ${1:-} == --apply ]] || { echo "dry-run; pass --apply to rewrite"; exit 0; }

[[ -s $list ]] || exit 0
bak=$home/.hermes/backups/rewrite-hermes-paths-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
tar -czf "$bak" --null -T "$list"
xargs -0 sed -i 's#/home/hermes\b#/home/agentops#g' < "$list"
echo "rewritten; backup: $bak"
