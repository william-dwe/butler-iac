# Open items

## Rename host user `hermes` to `agentops` (vendor-neutral)
Status: not started. Nothing below has been changed; this is the scoped checklist.

Why: the account owns Hermes, Paseo and (since 2026-10-11) a copy of omp state, so the name ties the host to one vendor.

Scope found 2026-10-11 (host uid/gid 1003, home `/home/hermes`):
- Ansible: `agent_user: hermes` in `ansible/inventory.yml` (46 references to `agent_user`), plus literal `/home/hermes`
  in `roles/hermes`, `roles/paseo`, `roles/butler`, `playbooks/backup.yml`; `roles/hermes/tasks/user.yml` creates the user.
- Compose: `roles/hermes/files/compose.yml` (`/home/hermes/.hermes`, `/home/hermes/workspace/research`, `HERMES_UID/GID=1003`)
  and `roles/paseo/files/compose.yml` (`user: 1003:1003`, `/home/hermes/.{paseo,omp,pi,hermes}`).
- Live state outside the repo: `/home/hermes/**` (`.hermes` 13 GB, `.paseo`, `.omp`, `.pi`, `.ssh`, `workspace`), sudoers
  `/etc/sudoers.d/90-hermes-agent` (temporary), `hermes-sudo-expire` timer, `/var/lib/butler` owned by hermes with `hermes` ACL entries.
- Absolute paths baked into data: Paseo `~/.paseo/config.json` (`/home/hermes/.hermes/hermes-agent/...`), Hermes configs
  and cron/session files, omp session JSON, wiki `SCHEMA.md` (`/home/hermes/workspace/research/`), `scripts/butler-review-queue.*`
  (container user `hermes`, `/opt/data/profiles/librarian/...`).
- Containers: the gateway image creates its own user `hermes` and maps `HERMES_UID/GID`; the in-container name does not have to change.
  Paseo runs with the host uid.

Safest approach: keep uid 1003, change only the name with `usermod -l agentops -d /home/agentops -m hermes` + `groupmod -n`,
leave a `/home/hermes` compatibility symlink until every absolute path is rewritten, then drop it. Stop all containers first;
take `backup.yml` beforehand. Do NOT rename while the Butler review timer or Paseo sessions are active.

Decide first: whether `HERMES_HOME`/`~/.hermes` (the product's own data dir) stays as is; only the OS account is vendor-neutral.

## Other
- Rollback of the Docker cutover to bare-metal is untested against the migrated `config.yaml` (schema 50).
  Host wrappers were moved to `/home/hermes/.local/bin.retired-20261011/`; `/home/hermes/.hermes/hermes-agent` is still used by Paseo's Hermes provider.
- `ansible/backups/` holds plaintext secrets (archives, old unit files); delete once a fresh `backup.yml` run is verified.
- `/home/hermes/.omp` and `/home/hermes/.pi` are a point-in-time copy of the `ubuntu` state and drift.
