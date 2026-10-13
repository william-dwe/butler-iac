#!/usr/bin/env bash
# Usage: scripts/terraform.sh <stack> <terraform args...>   e.g. scripts/terraform.sh cloudflare plan
# Runs Terraform in terraform/stacks/<stack> with secrets from stack.env (ubuntu-readable, allowlisted keys only).
# Reads individual keys instead of sourcing the file, so values are never evaluated by the shell.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
envfile=${STACK_ENV:-$HOME/.config/butler-iac/stack.env}
stack=${1:?usage: terraform.sh <stack> <terraform args...>}
shift
[ -d "$repo/terraform/stacks/$stack" ] || { echo "unknown stack: $stack" >&2; exit 1; }
get() { sed -n "s/^$1=//p" "$envfile" | head -n1 | sed -E 's/^"(.*)"$/\1/'; }

export CLOUDFLARE_API_TOKEN=$(get CLOUDFLARE_API_TOKEN)
export TF_VAR_tailscale_ip=$(tailscale ip -4 | sed -n '1p')
# R2 state backend (S3 API). Skipped until the keys exist, so `init -backend=false` and local runs still work.
if [ -n "$(get R2_ACCESS_KEY_ID)" ]; then
  export AWS_ACCESS_KEY_ID=$(get R2_ACCESS_KEY_ID) AWS_SECRET_ACCESS_KEY=$(get R2_SECRET_ACCESS_KEY)
  export AWS_ENDPOINT_URL_S3="https://$(get CLOUDFLARE_ACCOUNT_ID).r2.cloudflarestorage.com"
fi
exec terraform -chdir="$repo/terraform/stacks/$stack" "$@"
