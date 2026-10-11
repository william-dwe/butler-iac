#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
env=${STACK_ENV:-$HOME/.config/butler-iac/stack.env}
usage() {
  echo "Usage: $0 {restart|down|status|logs}" >&2
  exit 2
}

[ $# -eq 1 ] || usage
case $1 in restart|down|status|logs) ;; *) usage ;; esac
[ -d "$root/.git" ] || { echo "Missing infra checkout: $root" >&2; exit 1; }
[ -f "$env" ] && [ ! -L "$env" ] || { echo "Missing environment file: $env" >&2; exit 1; }
butler=$(sed -n 's/^BUTLER_DIR=//p' "$env")
wiki=$(sed -n 's/^WIKI_DIR=//p' "$env")
[[ $butler == /* && $wiki == /* && $butler != / && $wiki != / ]] || { echo "Invalid Butler path configuration in $env." >&2; exit 1; }
sudo test -d "$butler/.git" && sudo test -d "$wiki/.git" || { echo "Missing configured Butler or wiki checkout." >&2; exit 1; }

compose=(sudo docker compose --project-directory "$root" -f "$root/docker-compose.yml" --env-file "$env" -p butler-iac)

case $1 in
  restart) "${compose[@]}" restart backend frontend ;;
  down) "${compose[@]}" rm -sf backend frontend ;;
  status) "${compose[@]}" ps backend frontend ;;
  logs) "${compose[@]}" logs backend frontend ;;
esac
