#!/usr/bin/env bash
# Encrypted restic backup of agent state (everything under /home/agentops that is not regenerable).
# Runs as root from backup.timer. Control-plane secrets are NOT backed up: they re-render from .env + the
# dotenvx key in Ansible Vault. Live SQLite DBs are snapshotted with the online-backup API first.
# Default repo is LOCAL (same disk): protects against mistakes, not disk loss. For off-box, create
# ~/.config/butler-iac/backup.env (root 0600) with RESTIC_REPOSITORY + that backend's credentials.
set -euo pipefail

cfg=${BUTLER_IAC_CONFIG:-/home/ubuntu/.config/butler-iac}
[ ! -f "$cfg/backup.env" ] || { set -a; . "$cfg/backup.env"; set +a; }
export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-/home/ubuntu/backups/restic}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$cfg/backup.pass}
home=${BACKUP_HOME:-/home/agentops}
stage=/var/tmp/agent-backup-stage
tag=agent-state

[ "$EUID" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -s "$RESTIC_PASSWORD_FILE" ] || { echo "missing restic password file: $RESTIC_PASSWORD_FILE" >&2; exit 1; }
restic cat config >/dev/null 2>&1 || { echo "initialising repository $RESTIC_REPOSITORY"; restic init; }

rm -rf "$stage"; mkdir -p -m 700 "$stage"
trap 'rm -rf "$stage"' EXIT

# Consistent copies of every SQLite DB under the backed-up roots; originals (and -wal/-shm) are then excluded.
python3 - "$home" "$stage" <<'PY'
import os, sqlite3, sys
home, stage = sys.argv[1:3]
roots = [".hermes", ".paseo", ".omp", ".pi", "workspace", "data", "services"]
skip = {"hermes-agent", "cache", "logs", "node_modules", "models"}
done, failed = [], []
for r in roots:
    for d, dirs, files in os.walk(os.path.join(home, r)):
        dirs[:] = [x for x in dirs if x not in skip]
        for f in files:
            p = os.path.join(d, f)
            if not f.endswith((".db", ".sqlite", ".sqlite3")) or os.path.islink(p):
                continue
            try:
                with open(p, "rb") as fh:
                    if fh.read(16) != b"SQLite format 3\x00":
                        continue
                out = os.path.join(stage, os.path.relpath(p, "/"))
                os.makedirs(os.path.dirname(out), exist_ok=True)
                src = sqlite3.connect(f"file:{p}?mode=ro", uri=True, timeout=30)
                dst = sqlite3.connect(out)
                src.backup(dst)
                dst.close(); src.close()
                done.append(p)
            except Exception as e:
                failed.append((p, str(e)))
with open(os.path.join(stage, ".excluded"), "w") as ex:
    for p in done:
        ex.write("\n".join((p, p + "-wal", p + "-shm")) + "\n")
print(f"sqlite snapshots: {len(done)} ok, {len(failed)} failed (failed ones are backed up as plain files)")
for p, e in failed:
    print(f"  FAILED {p}: {e}", file=sys.stderr)
PY

restic backup --tag "$tag" --host vps --one-file-system --exclude-file "$stage/.excluded" \
  --exclude "$home/.hermes/hermes-agent" --exclude "$home/.hermes/cache" --exclude "$home/.hermes/logs" \
  --exclude "$home/.hermes/models_dev_cache.json" --exclude "$home/.paseo/models" --exclude "$home/.paseo/*.log" \
  --exclude '**/node_modules' --exclude "$stage/.excluded" \
  "$home/.hermes" "$home/.paseo" "$home/.omp" "$home/.pi" "$home/workspace" "$home/data" "$home/services" "$stage"

# Retention; prune and a light integrity check once a week.
if [ "$(date +%u)" = 7 ]; then
  restic forget --tag "$tag" --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  restic check --read-data-subset=2%
else
  restic forget --tag "$tag" --keep-daily 7 --keep-weekly 4 --keep-monthly 6
fi
restic snapshots --tag "$tag" --latest 1 --compact
