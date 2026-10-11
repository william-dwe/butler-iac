# butler-iac

VPS infrastructure for Hermes Agent dashboard, Butler dashboard and API, 9router LLM router, and Headroom prompt-compression sidecar.

![personal-agent-infra architecture](docs/architecture.svg)

Interactive version with summary cards: [docs/architecture.html](docs/architecture.html). Ownership and agent rules live in [AGENTS.md](AGENTS.md).

## Components

| Component | Runs as / network | Reach it at |
|---|---|---|
| Hermes gateway + dashboard | Docker containers `hermes-gateway`, `hermes-dashboard` (Compose, `ansible/roles/hermes`) | `http://<tailscale-ip>:9119` |
| 9router | Docker container; published host port | `http://<tailscale-ip>:20128` |
| Headroom | Docker `app-network` only | `http://headroom:8787` |
| Butler dashboard + API | Compose project `butler` from configured `BUTLER_DIR/compose.yml`; backend joins core Docker network only for 9router | Tailscale HTTPS `:8444` -> host loopback `:3100` |

## Quick start (new VPS)

> **Prerequisite:** Install Git and configure GitHub SSH access before cloning or deploying.
>
> ```bash
> sudo apt update && sudo apt install -y git openssh-client
> ssh-keygen -t ed25519 -C "you@example.com"
> cat ~/.ssh/id_ed25519.pub
> # Add output at https://github.com/settings/ssh/new, then verify:
> ssh -T git@github.com
> ```

Install Ansible and Git on the control node. Run locally from the new VPS, or target it over SSH from a laptop:

```bash
sudo apt-get install -y ansible git
```

Create the vault on the old VPS. `ansible/secret.txt` is one git-ignored line; store it in a password manager. `vault.yml` is ciphertext safe to commit.

```bash
cd ansible
(umask 077; openssl rand -base64 32 > secret.txt)
sudo cat /etc/dotenvx/personal-agent-infra.env.keys | python3 -c 'import json,sys; print("vault_dotenvx_private_key: " + json.dumps(sys.stdin.read()))' | ansible-vault encrypt --output group_vars/all/vault.yml
```

On the new VPS, clone this repo, write same one-line `ansible/secret.txt` with mode `0600`, then initialize host and deploy services. `butler-deploy` requires Hermes SSH access authorized for private Butler repo.

```bash
cd ansible
ansible-playbook playbooks/init.yml
ansible-playbook playbooks/services.yml
ansible-playbook playbooks/services.yml --tags butler-deploy
```

From a laptop:

```bash
ansible-playbook -i '<host>,' -u ubuntu playbooks/init.yml
ansible-playbook -i '<host>,' -u ubuntu playbooks/services.yml
ansible-playbook -i '<host>,' -u ubuntu playbooks/services.yml --tags butler-deploy
```

Add `-K` when sudo needs password. `init.yml` pauses for interactive Tailscale login. `services.yml` starts Headroom and 9router; `--tags butler-deploy` explicitly clones, updates, builds, and restarts Butler. Use `--tags <name>` to run another area.

`ansible/inventory.yml` holds environment-specific non-secret values (`admin_user`, `agent_user`, dashboard user, checkout path, repo URL, runtime env path). It also defines `butler_repo_url`, `butler_dir`, `butler_deploy_ref`, `wiki_repo_url`, and `wiki_dir`. Override them in another inventory for a different VPS. `init.yml` orders host prerequisites: `common`, `tailscale`, `hermes`, `devtools`, then `dotenvx`. `services.yml` starts Headroom and 9router. `services.yml --tags butler-deploy` deploys Butler at `butler_deploy_ref`. `main` deploys latest upstream `main`; use a tag or commit for repeatable deployment. `backup.yml` and `restore.yml` own migration orchestration.
`init.yml` installs `omp` at `/home/<admin_user>/.local/bin/omp` and links it at `/usr/local/bin/omp`.


Redeploy configured Butler ref:

```bash
ansible-playbook playbooks/services.yml --tags butler-deploy
```

Then enable the review timer manually (Hermes itself runs as Compose; start it with `ansible-playbook playbooks/services.yml --tags hermes,paseo`):

```bash
systemctl enable --now butler-review-queue.timer
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/deploy.sh [user]` | Legacy bare-metal systemd install of Hermes. Refuses to run while the `hermes-dashboard` container exists; not part of the Docker setup. |
| `scripts/menu.sh` | Whiptail control panel for status, dashboard controls, and Hermes sudo. |
| `scripts/check-headroom.sh` | Read-only 9router-to-Headroom smoke test. |
| `scripts/hermes-sudo.sh on\|off\|status` | Manage Hermes passwordless sudo grant. |
| `scripts/butler.sh restart\|down\|status\|logs` | Scoped Butler Compose control. Deploy through `ansible-playbook playbooks/services.yml --tags butler-deploy`. |
| `scripts/dotenv-env.sh render\|status` | Decrypt committed `.env` into `/etc/personal-agent-infra.env`, or report setup status without values. |

## Migration (existing VPS)

State migration stops Hermes, review timer, and all containers while archiving. Archives contain plaintext secrets from Hermes `.env`, librarian token, OMP user state, and 9router state; keep only in git-ignored `ansible/backups/`, then delete after migration.

```bash
# Old VPS
cd ansible && ansible-playbook playbooks/backup.yml

# New VPS, after init.yml and services.yml
ansible-playbook playbooks/restore.yml -e backup_file=backups/<name>.tar.zst
```

## Secrets

`.env` at repo root IS committed to this public repo, and that is intentional: it holds [dotenvx](https://dotenvx.com)-encrypted values (`KEY=encrypted:...`), not plaintext. The only secret-bearing runtime file is private key `/etc/dotenvx/personal-agent-infra.env.keys`, root-owned mode `0600`, generated once on VPS; its only copy outside VPS is Ansible Vault ciphertext `ansible/group_vars/all/vault.yml`, decryptable only with git-ignored one-line `ansible/secret.txt`. The `dotenvx` Ansible role installs the dotenvx CLI and a global (machine-level) git clean filter (`dotenvx protect`) that blocks committing plaintext `.env*` on this machine as a safety net.

`scripts/dotenv-env.sh render` (root only) decrypts `.env` using the private key, drops stale `TAILSCALE_IP`/`BUTLER_ORIGIN`/`BUTLER_WEB_ORIGIN` lines, injects current host-derived values for those three, and atomically installs root-owned `/etc/personal-agent-infra.env` mode `0600`. It never prints secret values. The `dotenvx`, `headroom`, and `butler` Ansible roles call it automatically. `scripts/dotenv-env.sh status` reports CLI/key/render state without values.

### Restore key from old VPS

Transferring `/etc/dotenvx/personal-agent-infra.env.keys` from an old VPS to a new one is an administrator-only, guided console action; it requires a manual authorization step on the old VPS and is not automated by Ansible or any script in this repo.

To add or rotate a secret, an administrator with the encrypted `.env` checked out runs, on a trusted terminal, never in chat:

```bash
dotenvx set SOME_KEY 'the-value' -f .env
```

This re-encrypts in place using the public key already embedded in `.env`'s header; it does not require the private key and does not decrypt anything else in the file. Commit the updated ciphertext normally, then request an approved `scripts/dotenv-env.sh render` run on the VPS. Keep `TAILSCALE_IP`, `BUTLER_ORIGIN`, and `BUTLER_WEB_ORIGIN` out of manual edits; the renderer supplies them from live host state.

To inspect decrypted values locally (admin only, never for agents):

```bash
dotenvx decrypt -f .env -fk /etc/dotenvx/personal-agent-infra.env.keys --stdout
```

## Security

- UFW denies incoming traffic by default; it allows `tailscale0` and TCP `22`.
- Dashboard uses `--insecure` on `0.0.0.0`; safety relies on UFW.
- 9router is published only on `TAILSCALE_IP`; Docker-published ports bypass UFW, so never bind `0.0.0.0`.
- Headroom must not publish host port or Tailscale Serve rule; 9router calls `/v1/compress` without token.
- `scripts/hermes-sudo.sh` grant and `docker` group membership are root-equivalent.
- Butler runs only through configured `BUTLER_DIR/compose.yml`; host ports remain loopback. Backend joins `personal-agent-infra_app-network` only for 9router; frontend stays private.
- `/var/lib/butler` is shared through named ACLs by `hermes` and `ubuntu`. Butler container runs as root only for portable bind-mount ownership; do not add `hermes` to Docker group.

## GitOps manifests

Image digests for auto-deployed services live in `manifests/` in this same repo. A systemd
timer (`gitops-pull-apply`, running as `ubuntu`, who owns the docker group) runs
`git pull --ff-only` on this checkout, then `docker compose pull && up -d` for each
`manifests/<service>/compose.yml`. Only the repo owner commits manifest changes; nothing
else gets docker-group access.

### Layout
- `manifests/<service>/compose.yml` -- one file per auto-deployed service.
- Image references use `@sha256:...` digests, never `:latest` tags, so a bump is a
  real, auditable file diff.

### Scope
Only butler-backend and butler-frontend are pulled from Williams private GCR; every
other image here is a public upstream vendor image (nousresearch/hermes-agent,
ghcr.io/getpaseo/paseo, prom/*, grafana/grafana, gcr.io/cadvisor/cadvisor).

9router and headroom are intentionally NOT managed here -- pinned manually, out of
scope for GitOps auto-deploy per project decision.
