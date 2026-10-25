#!/usr/bin/env bash
# Print the sorted names of every ${VAR} the compose files interpolate. stack-env.sh passes these keys through to stack.env,
# and gitops-env-sync.sh hashes this list, so adding a compose variable needs no allowlist edit and no manual re-render.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cat "$root"/docker-compose.yml "$root"/manifests/*/compose.yml | grep -oE '\$\{[A-Z][A-Z0-9_]*' | cut -c3- | grep -v '^DOTENV_' | sort -u
