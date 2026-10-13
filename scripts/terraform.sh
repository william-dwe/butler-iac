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

# CLOUDFLARE_API_TOKEN_OVERRIDE: one-off token with more scope (e.g. R2 edit for the r2-state stack); never stored.
export CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN_OVERRIDE:-$(get CLOUDFLARE_API_TOKEN)}
export TF_VAR_tailscale_ip=$(tailscale ip -4 | sed -n '1p')
export TF_VAR_account_id=$(get CLOUDFLARE_ACCOUNT_ID)
# R2 state backend (S3 API). Skipped until the keys exist, so `init -backend=false` and local runs still work.
if [ -n "$(get R2_ACCESS_KEY_ID)" ]; then
  export AWS_ACCESS_KEY_ID=$(get R2_ACCESS_KEY_ID) AWS_SECRET_ACCESS_KEY=$(get R2_SECRET_ACCESS_KEY)
  export AWS_ENDPOINT_URL_S3="${AWS_ENDPOINT_URL_S3:-https://$(get CLOUDFLARE_ACCOUNT_ID).r2.cloudflarestorage.com}"
fi
# Stacks on the R2 backend need the R2 keys; fail clearly instead of with an AWS credential error.
stack_dir=$repo/terraform/stacks/$stack
case ${1:-} in init|plan|apply|import|output|refresh|destroy|state|force-unlock)
  if grep -q 'backend "s3"' "$stack_dir"/*.tf && [ ! -f "$stack_dir/backend_override.tf" ] && [[ " $* " != *" -backend=false "* ]] \
     && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    echo "R2 state backend credentials missing: set R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY and CLOUDFLARE_ACCOUNT_ID (terraform/README.md)." >&2
    exit 1
  fi;; esac

exec terraform -chdir="$repo/terraform/stacks/$stack" "$@"
