#!/usr/bin/env bash
# Derive the ubuntu-readable GitOps stack.env from the root-only runtime.env (allowlisted keys only).
# WIKI_DIR/BUTLER_DIR come from the environment (Ansible) or, if unset, are kept from the existing stack.env.
# Run as root. Shared by the butler Ansible role and scripts/gitops-env-sync.sh.
set -euo pipefail
cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
runtime=${RUNTIME_ENV:-$cfg/runtime.env} stack=${STACK_ENV:-$cfg/stack.env} owner=${STACK_OWNER:-ubuntu}
for v in WIKI_DIR BUTLER_DIR; do
  [ -n "${!v:-}" ] || printf -v "$v" %s "$(sed -n "s/^$v=//p" "$stack" 2>/dev/null | head -n1)"
  [ -n "${!v}" ] || { echo "$v unset and not found in $stack" >&2; exit 1; }
done
tmp=$(mktemp "$(dirname "$stack")/.stack.env.XXXXXX")
trap 'rm -f "$tmp"' EXIT
# Static list = keys used outside compose (terraform.sh, env-set-api, butler.sh). Compose-referenced keys are added automatically, so
# a new ${VAR} in a manifest needs no edit here.
extra=$("$(dirname "$0")/compose-vars.sh" | paste -sd'|' -)
{ grep -E "^(BUTLER_[A-Z0-9_]+|API_SERVER_KEY|HERMES_WEBUI_PASSWORD|BROWSER_PASSWORD|TAILSCALE_IP|NINEROUTER_[A-Z0-9_]+|PUBLIC_[A-Z0-9_]+|CLOUDFLARE_[A-Z0-9_]+|R2_[A-Z0-9_]+${extra:+|$extra})=" "$runtime" || true
  printf 'WIKI_DIR=%s\nBUTLER_DIR=%s\n' "$WIKI_DIR" "$BUTLER_DIR"; } >"$tmp"
chown "$owner:$owner" "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$stack"
trap - EXIT
