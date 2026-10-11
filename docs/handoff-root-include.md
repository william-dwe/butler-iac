# Handoff: single root compose + all services under manifests/

Updated 2026-10-11. Code work for the 8 blocking problems is done in the worktree. **Nothing committed, nothing applied live.** Remaining: docs, commit, cutover.

## Goal
1. Root `docker-compose.yml` covers every service via `include:` of `manifests/<svc>/compose.yml`.
2. 9router + headroom move out of the root file into `manifests/`.
3. All deployment manifests centralized in one place.

## Where things are

| Location | State |
|---|---|
| Live checkout `/home/ubuntu/services/butler-iac` (`main`) | `a0ce3e9`, **not pushed**. **Uncommitted** edit to `ansible/roles/hermes/files/compose.yml` (+`/home/hermes/workspace/repos` mount). Already ported into worktree `manifests/hermes/compose.yml`; the live edit will conflict with the rename on merge. Discard it (`git checkout -- <file>`) after the worktree merges. |
| Worktree `/home/ubuntu/services/butler-iac-include` (`root-include`) | All changes below, uncommitted (mix of staged and unstaged). |
| Running containers | Unchanged. Only `a0ce3e9` applied. |

## Decisions (made by user this session)
- Hermes gateway <-> Butler backend: one shared non-external network named `butler_default` (the project default network).
- Runner: `gitops-pull-apply.timer` only, single root `up`. No Ansible role for 9router/headroom.
- Secrets: `butler` Ansible role renders `/etc/butler-iac/stack.env` (`root:ubuntu 0640`), including 9router secrets. `ubuntu` already has passwordless sudo.
- Isolation: accept shared default network for all services.

## Done in worktree
- `docker-compose.yml`: `name: butler-iac`, includes 9 manifests.
- `manifests/butler`: services use `default` + `app-network` (no external); `default` has `name: butler_default`.
- `manifests/hermes`: gateway on `default`; `networks:` block removed; repos mount added.
- `manifests/grafana`, `manifests/prometheus`: volumes pinned `grafana_grafana_data`, `prometheus_prometheus_data` (live names).
- `scripts/gitops-pull-apply.sh`: `git pull --ff-only`, then `docker compose --env-file /etc/butler-iac/stack.env -f docker-compose.yml pull` and `up -d --remove-orphans`. Fails hard if `stack.env` missing. **No per-manifest failure isolation any more.**
- `scripts/butler.sh`: uses root file, `stack.env`, `-p butler-iac`, scoped to `backend frontend`.
- `ansible/roles/butler/tasks/main.yml`: `butler.env` task replaced by `stack.env` task (adds `TAILSCALE_IP`, `NINEROUTER_*`). The CLI-extraction task still reads `manifests/butler/compose.yml` (unchanged, still valid).
- `ansible/playbooks/services.yml`: headroom/9router roles removed; hermes/paseo no longer set `hermes_compose`.
- `ansible/roles/hermes/tasks/{compose.yml,main.yml}`, `ansible/roles/paseo/tasks/main.yml`: compose tasks deleted; host setup kept (user, `config.json` seed, Tailscale IP assertion).
- Deleted: `scripts/check-headroom.sh`, roles `9router`, `headroom`. Lost with them: headroom Tailscale-rule-8787 cleanup (README now documents manual check with `docker port headroom` and `tailscale serve status`).
- `README.md`: components table, security notes, `check-headroom` row, dotenv paragraph updated.

## Verified
- `docker compose --env-file <fake env> config` from worktree root succeeds with no warnings. Output: project `butler-iac`; networks `app-network` (`butler-iac_app-network`) and `default` (`butler_default`); volumes `grafana_grafana_data`, `prometheus_prometheus_data`, `butler-iac_headroom_workspace`.
- Not run: `up`, `ansible-playbook` (even `--check`/syntax), healthchecks, any live container.

## Cutover risks (read before first `up`)
1. **Container-name conflicts.** Fixed `container_name`s (`grafana`, `prometheus`, `cadvisor`, `node-exporter`, `hermes-gateway`, `hermes-dashboard`, `paseo`, ...) already exist under old compose projects (`grafana`, `prometheus`, `hermes`, `paseo`, `butler`, ...). Root `up` fails with "name already in use". `down` each old project first (without `-v`; volumes survive). Order matters: stop old `butler` project last-needed-first only if gateway depends on `butler_default`.
2. **`butler_default` label clash.** Network exists today owned by project `butler`. Root project redefining it non-external may error or warn about wrong `com.docker.compose.project` label. Remove old network after `down` of project `butler` (so root recreates it), or declare it `external: true` and create it by hand. Test on `down` of old project, not before.
3. **`hermes-gateway` start order.** It needs backend reachable on `butler_default` for `scripts/butler-review-queue.sh` (`docker exec hermes-gateway curl http://backend:8765`). Smoke-test that after cutover.
4. **Run from the live checkout only.** `manifests/9router` mounts `../../data/9router`; from the worktree this is an empty `butler-iac-include/data/9router`. Merge the branch into `/home/ubuntu/services/butler-iac` before any `up`.
5. **`stack.env` does not exist yet.** Someone with root must run `ansible-playbook playbooks/services.yml --tags butler-deploy` (renders it; `AGENTS.md` forbids agents running `scripts/dotenv-env.sh render` and non-`--check` ansible). Until then the timer exits 1.
6. **Shared-failure blast radius.** One bad service (e.g. Tailscale down, `TAILSCALE_IP` unset -> `${TAILSCALE_IP:?}`) fails `config` for the whole stack, including monitoring.
7. **Network isolation regressed** (accepted): hermes-dashboard, butler-frontend, grafana, prometheus, cadvisor, node-exporter all on `butler_default`; hermes/paseo/core no longer isolated.
8. Untested: paseo healthcheck (`bash` in image) and `config.json` seed unchanged but paseo now runs under `butler-iac` project.

## Next steps
1. Docs still stale: `AGENTS.md` (component table rows for 9router/headroom point at root `docker-compose.yml`; Layout block "9router + headroom core project"; `check-headroom.sh` bullet and layout line), `README.md` (GitOps "Scope"/`<svc>.env` text at ~L154-158 and `services.yml starts Headroom and 9router` at ~L61/L63; check-headroom mention), `docs/open-items.md` (L11-12 old `roles/*/files/compose.yml` paths), `docs/architecture.{svg,html}`, `docs/vps-docker-cutover-*.md`.
2. `ansible-playbook --check` the playbook (`ansible-playbook --syntax-check` is read-only) to confirm roles still load after deletions.
3. Commit on `root-include`; merge into live `main`; discard the live uncommitted hermes edit.
4. User runs `services.yml --tags butler-deploy` to render `stack.env`, then cutover per risks 1-3: `down` old projects, remove `butler_default`, run `scripts/gitops-pull-apply.sh` by hand, verify `docker compose ps`, Prometheus targets `node`/`cadvisor` up, Grafana 200, `docker port headroom` empty, gateway -> `backend:8765`.
5. Abandon instead: `git worktree remove ../butler-iac-include && git branch -D root-include` (from live checkout).

## Open items (unchanged)
- agentops half still missing (clone in `/srv/deploy-manifests/butler-iac` removed; digest bumps are manual commits).
- Herdr OMP integration not ported.
- `ghcr.io` login for `ubuntu` done by hand (`gh auth token`), not in Ansible; `butler` role's CLI-extraction depends on it.
- `/etc/butler-iac/butler.env` was created by hand and is now superseded by `stack.env`; remove the old file after cutover.
- `/srv/butler`, `/etc/personal-agent-infra.paths`, `scripts/butler-paths.sh` leftovers.
