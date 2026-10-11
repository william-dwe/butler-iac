# VPS Docker Migration — Cutover Runbook

Status: EXECUTED 2026-10-10 (hermes-gateway, hermes-dashboard, paseo now Docker). This step actually switches hermes-gateway,
hermes-dashboard, and paseo from bare-metal systemd units to Docker containers. It is
deliberately human-reviewed and NOT something OMP or Orchestrator runs unattended.

## Pre-conditions (all true as of 2026-10-10)
- All role/playbook work for this migration committed on `main` in
  `/home/ubuntu/services/personal-agent-infra` (commits through `1018689`), NOT pushed.
- `hermes` and `paseo` roles are tagged `[hermes, never]` / `[paseo, never]` in
  `services.yml` — a normal `ansible-playbook services.yml` run skips them; only an
  explicit `--tags hermes,paseo` run touches them.
- `ansible-playbook services.yml --check --diff --tags hermes,paseo` passes clean
  (0 failed) as of last verification.
- Live bare-metal services confirmed active and untouched: `hermes-gateway@hermes`,
  `hermes-dashboard@hermes`, `paseo.service`.

## What changes
- `hermes-gateway@hermes` + `hermes-dashboard@hermes` (bare systemd, Python venv) →
  two Docker containers from `nousresearch/hermes-agent` image, same `~/.hermes` bind
  mount, same ports (8642 internal only, 9119 on Tailscale IP).
- `paseo.service` (bare systemd) → one Docker container from `ghcr.io/getpaseo/paseo`
  image, `network_mode: host`, same `~/.paseo` + `~/.hermes` bind mounts, plus a new
  `/opt/omp:/opt/omp:ro` mount for its `paseo-omp` provider.
- Paseo's "Hermes" ACP provider entry is REMOVED (decided out of scope — see
  session notes; Paseo can't reach a live Hermes session over network, only a fresh
  local subprocess, and that subprocess needs a full Python runtime copy we decided
  wasn't worth it).

## Rollback point
Before touching anything: take a real backup.
```
ansible-playbook playbooks/backup.yml
```
This produces `backups/pai-<host>-<timestamp>.tar.zst` fetched to the control
machine. Confirm it exists and is non-empty before proceeding. If cutover goes wrong,
`ansible-playbook playbooks/restore.yml -e backup_file=backups/<name>.tar.zst` is the
documented rollback (stops services, extracts archive, restarts services).

## Cutover steps
1. **Dry run first, always:**
   ```
   ansible-playbook playbooks/services.yml --check --diff --tags hermes,paseo
   ```
   Confirm 0 failed. If anything's red, stop — do not proceed to step 2.

2. **Take the backup** (see Rollback point above). Do not skip this.

3. **Stop the bare-metal services manually** (the `hermes`/`paseo` roles' compose-up
   tasks don't stop the old systemd units themselves — that's intentional, so a
   `--check` run never touches live state):
   ```
   sudo systemctl stop hermes-gateway@hermes hermes-dashboard@hermes paseo.service
   sudo systemctl disable hermes-gateway@hermes hermes-dashboard@hermes paseo.service
   ```

4. **Run the real cutover:**
   ```
   ansible-playbook playbooks/services.yml --tags hermes,paseo
   ```

5. **Verify containers are up and healthy:**
   ```
   docker ps --filter "name=hermes-gateway" --filter "name=hermes-dashboard" --filter "name=paseo"
   curl -s http://127.0.0.1:8642/health   # expect 200 (or whatever the real health check needs)
   ```
   Check `docker logs hermes-gateway`, `docker logs hermes-dashboard`,
   `docker logs paseo` for startup errors — especially the two `ponytail:`-flagged
   unverified assumptions in the compose files:
   - `HERMES_UID`/`HERMES_GID` env vars actually honored by the entrypoint (unverified).
   - Paseo's healthcheck command (`bash -c 'exec 3<>/dev/tcp/...'`) — `bash` presence
     in the Paseo image unverified.

6. **Functional check from a real client** (Telegram message, or dashboard at
   `http://<tailscale-ip>:9119`) — confirm Hermes responds and session/memory look
   intact (same recent conversation history visible).

7. **If anything's wrong:** stop the new containers (`docker compose -f
   ansible/roles/hermes/files/compose.yml down`, same for paseo), re-enable +
   restart the old systemd units, and consider `restore.yml` if state got corrupted.

8. **If everything's good:** leave the old systemd units disabled (don't delete
   their unit files yet — keep as a fallback for one full cycle of normal use,
   e.g. a few days, before removing `/home/hermes/.local/bin/hermes`,
   `/home/hermes/.local/bin/paseo`, and their systemd unit files for real).

## Known open risks (carried from Brief D/E review, not yet resolved)
- `HERMES_UID`/`HERMES_GID` env var honoring by the image entrypoint — unverified.
- Container UID `1003:1003` for paseo forced for bind-mount ownership — untested.
- Healthcheck commands' binary existence inside each image — unverified
  (`/opt/hermes/.venv/bin/python` for hermes, `bash` for paseo).
- `API_SERVER_KEY` needs to be set in `.env` before first `docker compose up` —
  the compose file has `:?set API_SERVER_KEY in .env}`, so it'll fail loudly if
  missing, not silently.
- `deploy.sh` and its systemd-unit-linking logic are NOT updated for compose —
  deliberately out of scope; it only matters if you ever need to re-run it for the
  bare-metal fallback path.

## Explicitly out of scope for this runbook
- Blue-green / zero-downtime cutover — deferred to wiki
  (`staging/concepts/vps-docker-ansible-migration.md`). This runbook is a planned
  downtime cutover (steps 3-4 stop the old thing before starting the new thing).
- 9router role changes — untouched, pinned digest, manual-bump-only.
- Paseo's Hermes ACP integration — dropped, see "What changes" above.

## Findings from the 2026-10-10 execution
- `API_SERVER_KEY` must exist in TWO places. The compose `:?` check reads `/etc/personal-agent-infra.env`
  (rendered from the dotenvx-encrypted `.env`; add with `dotenvx set API_SERVER_KEY '<v>' -f .env`, then
  `scripts/dotenv-env.sh render`). The gateway runs multiplexed (default/librarian/orchestrator/researcher), where
  `agent/secret_scope.py` treats `API_SERVER_ENABLED/HOST/PORT` as global env but `API_SERVER_KEY` as a profile
  credential read only from the profile `.env`. Without the key in `/home/hermes/.hermes/.env` the API server never
  starts and the compose healthcheck on `127.0.0.1:8642/health` stays unhealthy. Rotate in both places.
- `docker compose ... --env-file /etc/personal-agent-infra.env` needs root (file is `root:root 0600`); use `sudo` or Ansible.
- The first `--tags hermes,paseo` run failed on `--wait` (gateway unhealthy) and never reached paseo; re-run `--tags paseo`.
- Container start migrates `config.yaml` schema 49 -> 50 (backups in `/home/hermes/.hermes/backups/config/`).
  Rollback to the bare-metal binary is untested against the new schema.
- `backup.yml` stops all services/containers (~2.5 min). 9router's real bind mount is `/srv/agent-infra/data/9router`
  (compose project dir `/srv/agent-infra`, not `infra_dir`). `router_data_dirs` in `inventory.yml` now lists both roots;
  `backup.yml` archives whichever exist and `restore.yml` only wipes a `9router` dir the archive replaces.
  The 2026-10-10 archive predates this fix; its 9router data is in `backups/pai-9router-srv-20261011.tar.zst`.
- Verified: HERMES_UID/GID honored (entrypoint logs "Changing hermes UID to 1003"); paseo healthcheck passes.
- Butler review queue now runs through the container. `butler-review-queue.service` runs as `ubuntu` (docker group; `hermes`
  has no docker access) and `scripts/butler-review-queue.sh` does the pending-count gate and `hermes -p librarian chat`
  via `docker exec -u hermes hermes-gateway`. The gateway joins the external `butler_default` network (Butler API at
  `http://backend:8765`) and bind-mounts `/var/lib/butler`; the librarian prompt uses that URL and the container token path.
  The `/usr/local/lib/personal-agent-infra/butler-review-queue.sh` symlink was repointed from `/srv/agent-infra` to this
  checkout. Paseo<->Hermes/omp integration is intentionally NOT migrated (host-only `hermes`, `paseo-omp` wrappers remain).
  Not covered: SCHEMA.md's `/home/hermes/workspace/research/` and `~/backups/second-brain/` host paths do not exist in the container.
- Research mount: `hermes-gateway` bind-mounts `/home/hermes/workspace/research` (SCHEMA.md `raw/briefings/` source path).
- Paseo providers now run inside the container. `omp` state moved to hermes ownership: `/home/hermes/.omp` and
  `/home/hermes/.pi` (the latter holds `agent/9router.json`, the 9router endpoint+key read by the `@qmahyar/pi-9router`
  plugin) are mounted at `/home/paseo/.omp` and `/home/paseo/.pi`; `~/.paseo/config.json` `agents.providers.omp.command`
  is `/opt/omp/bin/omp` and `providers.hermes.command` is `/home/hermes/.hermes/hermes-agent/.hermes/bin/hermes -p orchestrator acp`
  (depends on that host checkout; backup of the old config: `config.json.pre-omp-move`). Do NOT set `PI_CODING_AGENT_DIR`
  in the container: omp then fails to load its native addon. The `paseo-omp` sudo wrapper and `/etc/sudoers.d/paseo-omp` are now unused.
- `/home/ubuntu/.omp` and `/home/ubuntu/.pi` are still the live state of the admin omp session; the hermes copies were taken
  2026-10-11 and are NOT kept in sync. `backup.yml` archives both.
