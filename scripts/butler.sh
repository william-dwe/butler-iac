#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
env=/etc/butler-iac/butler.env
mapfile -d '' -t paths < <("$root/scripts/butler-paths.sh")
[ "${#paths[@]}" -eq 2 ] || { echo "Invalid Butler path configuration." >&2; exit 1; }
butler=${paths[0]}
wiki=${paths[1]}
usage() {
  echo "Usage: $0 {restart|down|status|logs}" >&2
  exit 2
}

[ $# -eq 1 ] || usage
case $1 in restart|down|status|logs) ;; *) usage ;; esac
[ -d "$root/.git" ] || { echo "Missing infra checkout: $root" >&2; exit 1; }
sudo test -d "$butler/.git" && sudo test -d "$wiki/.git" || { echo "Missing configured Butler or wiki checkout." >&2; exit 1; }
sudo test -f "$env" && ! sudo test -L "$env" || { echo "Missing environment file: $env" >&2; exit 1; }

compose=(sudo docker compose --project-directory "$root/manifests/butler" -f "$root/manifests/butler/compose.yml" --env-file "$env")

case $1 in
  restart) "${compose[@]}" restart ;;
  down) "${compose[@]}" down ;;
  status) "${compose[@]}" ps ;;
  logs) "${compose[@]}" logs ;;
esac
