#!/usr/bin/env bash
# Zero-token gate: start a librarian run only when Butler has review packets waiting.
# Runs as ubuntu (docker group) from butler-review-queue.timer; gate and librarian execute inside
# the hermes-gateway container, which reaches Butler on butler_default. Token never appears in argv or logs.
set -euo pipefail
script=$(readlink -f "$0")
root=$(cd "$(dirname "$script")/.." && pwd)
prompt=$root/scripts/butler-review-queue.prompt.md
token_file=/opt/data/profiles/librarian/secrets/butler-librarian.token # container path
base=http://backend:8765/api/librarian/review-packets

exec 9>/var/lib/butler/review-queue.lock
flock -n 9 || { echo "previous run still active"; exit 0; }

pending=$(docker exec -i -u hermes hermes-gateway bash -c 'curl -fsS --max-time 10 -H @- "$0/pending-count" <<<"Authorization: Bearer $(<"$1")"' "$base" "$token_file" |
  python3 -c 'import json,sys; print(int(json.load(sys.stdin)["pending"]))')

if [ "$pending" -eq 0 ]; then
  exit 0
fi
echo "pending=$pending; starting librarian"
exec docker exec -i -u hermes hermes-gateway hermes -p librarian chat -Q --query-file - <"$prompt"
