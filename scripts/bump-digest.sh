#!/usr/bin/env bash
# Usage: bump-digest.sh <compose-file> <image> <sha256:digest>
# Repins `image: <image>@sha256:...` in a manifest. Used by .github/workflows/bump-digest.yml.
set -euo pipefail
file=$1 image=$2 digest=$3
[[ $digest =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "bad digest: $digest" >&2; exit 1; }
[[ $image =~ ^[a-z0-9./_-]+$ ]] || { echo "bad image: $image" >&2; exit 1; }
grep -qE "image: *${image}@sha256:" "$file" || { echo "no digest pin for $image in $file" >&2; exit 1; }
sed -i -E "s#(image: *${image})@sha256:[a-f0-9]{64}#\1@${digest}#" "$file"
