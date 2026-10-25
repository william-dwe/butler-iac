#!/usr/bin/env bash
# Bring this checkout up to date with origin without ever failing on divergence, and publish pending .env commits.
#   scripts/git-sync.sh              fast-forward; if local commits exist (e.g. the Secrets page's "env: set KEY"), rebase them onto origin
#   scripts/git-sync.sh --push-env   same, then push local commits to origin, but ONLY if they touch nothing except .env
# Runs as ubuntu from gitops-pull-apply.service (ExecStartPre, every minute), gitops-pull-apply.sh and env-set-api.py. Serialised
# with flock because those can overlap. A rebase conflict (e.g. .env also edited upstream) is aborted and fails loudly, which
# triggers the GitOps Telegram alert; origin is never force-pushed.
set -euo pipefail
repo=${GITOPS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
push=0; [ "${1:-}" != --push-env ] || push=1
git=(git -C "$repo" -c user.name=Ubuntu -c user.email=ubuntu@localhost.localdomain)

exec 9>"$repo/.git/butler-sync.lock"
flock -w "${GIT_SYNC_LOCK_WAIT:-50}" 9 || { echo "git-sync: another sync holds the lock" >&2; exit 1; }

update() {
  "${git[@]}" fetch --quiet origin
  # Merging an ancestor is a no-op, so this also succeeds when we are only ahead.
  "${git[@]}" merge --ff-only --quiet '@{u}' 2>/dev/null && return 0
  # ponytail: --autostash keeps unrelated uncommitted edits in the working tree; it cannot help if they conflict with incoming changes.
  "${git[@]}" rebase --autostash --quiet '@{u}' || { "${git[@]}" rebase --abort 2>/dev/null || true; echo "git-sync: rebase onto origin failed; resolve by hand" >&2; return 1; }
}

update
[ "$push" = 1 ] || exit 0

for attempt in 1 2 3; do
  [ "$("${git[@]}" rev-list --count '@{u}..HEAD')" -gt 0 ] || exit 0
  other=$("${git[@]}" diff --name-only '@{u}' HEAD | grep -vxF .env || true)
  [ -z "$other" ] || { echo "git-sync: local commits also touch other files; not pushing them" >&2; exit 0; }
  branch=$("${git[@]}" rev-parse --abbrev-ref '@{u}'); branch=${branch#*/}
  if "${git[@]}" push --quiet origin "HEAD:refs/heads/$branch" 2>/dev/null; then echo "git-sync: pushed .env commits to origin/$branch"; exit 0; fi
  update  # lost a race with a deploy bump: rebase onto it and retry
done
echo "git-sync: push failed after 3 attempts" >&2
exit 1
