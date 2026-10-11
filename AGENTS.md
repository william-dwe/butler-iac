# AGENTS.md: personal-agent-infra

Shared VPS infrastructure for a personal agent team: Hermes Agent dashboard,
Butler orchestrator, 9router LLM router, and Headroom compression sidecar. This repo holds infra only:
no wiki notes or Butler application code.

## Ownership and boundaries

|Path|Owner|Who writes it|
|---|---|---|
|This infra checkout|Script-derived root|`ubuntu` only. Agents running as `agentops` (renamed from `hermes`; `/home/hermes` is a compat symlink) deliver changes as a `git apply` patch for the administrator to run as `ubuntu`.|
|Butler and wiki checkouts|`BUTLER_DIR` and `WIKI_DIR` in `~/.config/butler-iac/stack.env`|`agentops`; wiki only librarian writes after the administrator approves.|
|`/home/ubuntu/services/second-brain-service`|`ubuntu`|Legacy checkout. Retire it after migration; don't add features to it.|

- Before editing any `services/...` path, check its absolute path and owner. Similar-looking copies have been edited by mistake before.
- Remote `origin` is the PUBLIC repo github.com/william-dwe/butler-iac. Push only with the administrator's approval. `.env` IS committed (dotenvx-encrypted, see README Secrets); never commit `data/`, real IPs, tokens, or a plaintext `.env`/`.env.keys` (the global `dotenvx protect` git filter blocks this as a safety net).
- Don't change global Git config. Set the commit identity per command, e.g. `git -c user.name=Ubuntu -c user.email=ubuntu@localhost.localdomain commit`.

## What runs here

|Component|Defined in|Runs as|Reach it at|
|---|---|---|---|
|Hermes dashboard (web + TUI)|`systemd/hermes-dashboard@.service`|`hermes-dashboard@<user>` (`hermes` or `ubuntu`, stored in `.dashboard-user`)|`http://<tailscale-ip>:9119`|
|Butler dashboard + API|`manifests/butler/compose.yml` project `butler-iac`|containers; shared default network `butler_default`|Tailscale HTTPS `:8444` -> host loopback `:3100` -> `127.0.0.1:8765`|
|9router (LLM router)|`manifests/9router/compose.yml`|container `9router`|`http://<tailscale-ip>:20128`|
|Headroom (prompt compression)|`manifests/headroom/compose.yml`|container `headroom`|`http://headroom:8787`, Docker network only|

- Only one user can run the dashboard, because only one process can listen on `:9119`. `scripts/deploy.sh <user>` links the unit, stops the others, and restarts the dashboard, which drops open browser and agent sessions.
- 9router calls Headroom's `/v1/compress` without a token. For that reason Headroom must not publish a host port or a Tailscale Serve rule. Verify with `docker port headroom` (must be empty) and `tailscale serve status`.
- The network is locked down by UFW (role `common`, `tasks/firewall.yml`): incoming traffic is denied by default, except `tailscale0` and port 22. The dashboard runs with `--insecure` on `0.0.0.0` and depends on this firewall.
- 9router is published only on the Tailscale IP (`TAILSCALE_IP` rendered into `~/.config/butler-iac/runtime.env`; get it with `tailscale ip -4`). Never publish on `0.0.0.0`, because Docker-published ports bypass UFW.

## Layout

```text
docker-compose.yml             root project (butler-iac); include:s manifests/*/compose.yml
manifests/<svc>/compose.yml    one compose file per service
systemd/                       hermes-dashboard@.service template (EnvironmentFile = ~/.config/butler-iac/runtime.env)
ansible/                       inventory.yml stores environment vars; playbooks/init.yml initializes host; playbooks/services.yml deploys core services and Butler; backup.yml/restore.yml own migration
scripts/butler.sh              scoped Butler Compose restart/down/status/logs; reads `BUTLER_DIR`/`WIKI_DIR` from `stack.env`
scripts/deploy.sh [user]       link unit + switch dashboard user
scripts/menu.sh                whiptail ops panel (status, dashboard controls, hermes sudo)
scripts/hermes-sudo.sh         sudo ./scripts/hermes-sudo.sh on|off|status
scripts/dotenv-env.sh          render|status for ~/.config/butler-iac/runtime.env
```

Not tracked (see `.gitignore`): `.env.keys` (dotenvx private key material, never generated here—lives root-only on the VPS), `.dashboard-user`, `data/` (9router DB), `.archive/`. `.env` itself IS tracked, dotenvx-encrypted.

VPS migration (backup old VPS -> `init.yml` on new VPS -> `services.yml` -> restore): see README.md "Migration (existing VPS)".

Butler role writes `BUTLER_DIR` and `WIKI_DIR` (absolute, from inventory) into `~/.config/butler-iac/stack.env`. Changing live locations requires an approved Butler stop, inventory update, and deploy.

## Architecture diagram

`docs/architecture.{svg,html}` are maintained by Hermes, not by `ubuntu` agents. They predate the single-root-compose change; Hermes should update them to show:
- one root `docker-compose.yml` (project `butler-iac`) that `include:`s every `manifests/<svc>/compose.yml` (butler, hermes, paseo, 9router, headroom, node-exporter, cadvisor, prometheus, grafana);
- a shared project default network `butler_default` for all services (accepted isolation regression), plus `app-network` for backend/9router/headroom;
- secrets from `~/.config/butler-iac/stack.env`, applied by the `gitops-pull-apply` timer, with no per-service Ansible roles for 9router or headroom.

## Env secrets

- dotenvx-encrypted `.env` (committed to this repo) is source of runtime secrets. `~/.config/butler-iac/dotenvx.keys` is root-owned mode `0600`; only Ansible Vault ciphertext `ansible/group_vars/all/vault.yml` stores it outside VPS. Agents never read either key material. `~/.config/butler-iac/runtime.env` is root-owned (0600) rendered runtime config; `stack.env` there is ubuntu-owned (0600) for the GitOps timer. The directory is `/home/ubuntu/.config/butler-iac` (control plane lives under ubuntu, never under the agents' home).
- Agents never read `ansible/secret.txt`, never run `ansible-vault view|decrypt|edit|encrypt`, and never run `playbooks/init.yml`/`playbooks/services.yml`/`playbooks/backup.yml`/`playbooks/restore.yml` without `--check` unless the administrator approves; `backup.yml` stops services.
- Agents may run `scripts/dotenv-env.sh status` only. Agents never run `scripts/dotenv-env.sh render`, `dotenvx decrypt`, `dotenvx encrypt` on committed `.env`, or read `~/.config/butler-iac/dotenvx.keys`. Transferring the dotenvx private key between VPSes is an administrator-only guided console action; agents don't automate or participate in it. Adding a new key via `dotenvx set KEY value -f .env` doesn't need the private key, but still ask the administrator to run it themself—an agent-entered value can't be confirmed without ever appearing in chat.
- When changing secret keys or `.env.example`, report key names and ask the administrator to update the encrypted `.env` manually; never ask for or print values in chat.

## Security-sensitive knobs

- `scripts/hermes-sudo.sh on` writes `/etc/sudoers.d/90-hermes-agent`, which gives `hermes` passwordless root. `off` removes only that file.
- Membership in the `docker` group is also root-equivalent, so `hermes` in `docker` means `hermes` is effectively root.
- Mention either one whenever a change touches `hermes` permissions.
- `/home/agentops/data/butler` (role `butler`, `tasks/main.yml`; container path `/var/lib/butler`) is read-write for `agentops`, `ubuntu`, and root via ACLs. It holds administrator task DB and attachments.
- Butler runs from Compose with a root backend only because host `hermes` UID is not portable into images. Backend has a read-write `/home/agentops/data/butler` mount and read-only wiki mount; host CLI remains `hermes`. Do not add `hermes` to Docker group.

## Working here

- Before proposing Ansible changes, run `cd ansible && ansible-playbook playbooks/init.yml playbooks/services.yml playbooks/backup.yml playbooks/restore.yml --syntax-check`.
- Before proposing a change, run `bash -n scripts/*.sh`, relevant Python tests, `scripts/dotenv-env.sh status`, and `systemd-analyze verify systemd/*.service`. Agents never run `scripts/dotenv-env.sh render`, `dotenvx decrypt`, `dotenvx encrypt` on committed `.env`, or `docker compose` against live services.
- Base-host initialization (packages, Docker, Tailscale, shell, firewall, Hermes user/agent, dotenvx) lives in `ansible/playbooks/init.yml`; core services and Butler deployment live in `ansible/playbooks/services.yml`. Don't reintroduce parallel Bash setup for steps either playbook covers.
- Keep scripts short and use Bash and core utilities only. Mark deliberate shortcuts with a `# ponytail:` comment that names the limit.
- If `docker` shows "unknown" or permission denied right after `usermod -aG docker`, the session has stale groups, often from a shared SSH ControlMaster connection. Run `exec sudo -iu ubuntu` rather than reconnecting.
- The following restart live services, so ask administrator before running them: `deploy.sh`, `systemctl restart`, `scripts/butler.sh restart`, `scripts/butler.sh down`, or `ansible-playbook playbooks/services.yml --tags butler-deploy`.
