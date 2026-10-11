# Open items

## Rename host user `hermes` to `agentops` (vendor-neutral)
Status: break analysis done 2026-10-11; nothing renamed. `agentops` is free (the GitOps account was removed; GitOps runs as `ubuntu`).

Why: the account owns Hermes, Paseo and (since 2026-10-11) a copy of omp state, so the name ties the host to one vendor.

Would break if renamed without fixing (host uid/gid 1003, home `/home/hermes`):
- Ansible: `agent_user: hermes` in `ansible/inventory.yml` (46 references to `agent_user`), plus literal `/home/hermes`
  in `roles/hermes`, `roles/paseo`, `roles/butler`, `playbooks/backup.yml`; `roles/hermes/tasks/user.yml` creates the user.
- Compose: `manifests/hermes/compose.yml` (`/home/hermes/.hermes`, `/home/hermes/workspace/research`, `HERMES_UID/GID=1003`)
  and `manifests/paseo/compose.yml` (`user: 1003:1003`, `/home/hermes/.{paseo,omp,pi,hermes}`).
- Live state outside the repo: `/home/hermes/**` (`.hermes` 13 GB, `.paseo`, `.omp`, `.pi`, `.ssh`, `workspace`), sudoers
  `/etc/sudoers.d/90-hermes-agent` (temporary), `hermes-sudo-expire` timer, `/var/lib/butler` owned by hermes with `hermes` ACL entries.
- Absolute paths baked into data: Paseo `~/.paseo/config.json` (`/home/hermes/.hermes/hermes-agent/...`), Hermes configs
  and cron/session files, omp session JSON, wiki `SCHEMA.md` (`/home/hermes/workspace/research/`), `scripts/butler-review-queue.*`
  (container user `hermes`, `/opt/data/profiles/librarian/...`).
- Containers: the gateway image creates its own user `hermes` and maps `HERMES_UID/GID`; the in-container name does not have to change.
  Paseo runs as `1003:1003` (numeric, survives a rename) but bind-mounts `/home/hermes/...` sources (compose literals, 8 lines in the two compose files).
- Also by name: `/etc/subuid` and `/etc/subgid` entries for `hermes`, three ACL entries naming `hermes` under `/var/lib/butler`,
  `/etc/sudoers.d/90-hermes-agent` and the `hermes-sudo-expire` units, and 154 files under `~/.hermes/profiles` holding `/home/hermes`.
- Legacy `systemd/hermes-{gateway,dashboard}@.service` and `scripts/deploy.sh`/`menu.sh` assume the name; they are unused since the cutover.

Safest approach: keep uid 1003, change only the name with `usermod -l agentops -d /home/agentops -m hermes` + `groupmod -n`,
leave a `/home/hermes` compatibility symlink until every absolute path is rewritten, then drop it. Stop all containers first;
take `backup.yml` beforehand. Do NOT rename while the Butler review timer or Paseo sessions are active.
Never edit the upstream Hermes checkout (`~/.hermes/hermes-agent`) to fix paths; fix our compose/config instead, or keep the symlink.
Decide first: whether `HERMES_HOME`/`~/.hermes` (the product's own data dir) stays as is; only the OS account is vendor-neutral.

## Other
- Rollback to bare metal is not planned (owner decision 2026-10-11) and untested against the schema-50 `config.yaml`.
  Host wrappers are in `/home/hermes/.local/bin.retired-20261011/`; `/home/hermes/.hermes/hermes-agent` is still used by Paseo's Hermes provider and must not be edited.
- `ansible/backups/` holds plaintext secrets (archives, old unit files, ~6 GB); delete once you are satisfied with the 2026-10-11 archive.
- `/home/hermes/.omp` and `/home/hermes/.pi` are a point-in-time copy of the `ubuntu` state and drift.
- Monitoring (node-exporter, cAdvisor, Prometheus, Grafana) is deployed by the root compose (`manifests/*`) and scraped over the shared `butler_default` network by service name.
- The Paseo Hermes provider logs `CLI exposure failed: Permission denied: /home/paseo/.local/bin` and retries an interrupted source update on every start (`installs/*/source-completion-pending`). It still answers ACP `initialize`.
