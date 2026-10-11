#!/usr/bin/env bash
# Pull this repo (butler-iac), then compose pull + up -d for each manifests/<svc>/compose.yml.
# Runs as ubuntu (docker group) from gitops-pull-apply.timer. Logs to journald.
# Exit non-zero only if git pull fails; a broken manifest is logged and skipped.
set -uo pipefail
repo=${GITOPS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}

git -C "$repo" pull --ff-only || { echo "git pull failed in $repo" >&2; exit 1; }

failed=0
for dir in "$repo"/manifests/*/; do
  [ -f "$dir/compose.yml" ] || continue
  name=$(basename "$dir")
  echo "apply: $name"
  if (cd "$dir" && docker compose -f compose.yml pull && docker compose -f compose.yml up -d); then
    echo "ok: $name"
  else
    echo "FAILED: $name" >&2; failed=$((failed + 1))
  fi
done
echo "done: $failed manifest(s) failed"
exit 0 # ponytail: per-manifest failures only visible in logs; add non-zero exit if alerting is wired to unit failure.
