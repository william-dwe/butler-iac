# Cutover Handoff — for OMP (elevated permissions, this task only)

**Read this fully before touching anything.** You are being given permissions
beyond your normal file-authoring-only restriction for this one task: you may
run `systemctl`, `docker compose`, and stop/start the live bare-metal Hermes and
Paseo services. This is a one-time elevation for the cutover described below —
do not treat future tasks as having these permissions unless told explicitly
again.

## What you're doing
Switch 3 live bare-metal services to Docker containers, following the
already-written runbook at `docs/vps-docker-cutover-runbook.md` in this repo
(`/home/ubuntu/services/butler-iac`, branch `main`, already pushed to
`github.com/william-dwe/personal-agent-infra`). Read that file first — it's the
primary instruction set. This handoff adds context/preconditions it doesn't
cover and should be read alongside it, not instead of it.

## Non-negotiable requirement: preserve ALL state
William's explicit requirement: **retain every config, conversation, memory —
everything.** This is largely already satisfied by design, not something you
need to build:
- `manifests/hermes/compose.yml` bind-mounts the REAL
  `/home/hermes/.hermes` directory straight into the container at `/opt/data`
  (not a copy). `state.db` (all sessions/conversations), `config.yaml`, skills,
  memory — all of it is the same files the bare-metal process uses today. The
  container reads/writes the identical data.
- `manifests/paseo/compose.yml` likewise bind-mounts the real
  `/home/hermes/.paseo` and `/home/hermes/.hermes`.
- **Your job is to NOT break this property.** Do not copy, truncate, or
  reinitialize any of `~/.hermes` or `~/.paseo` content. Do not run any
  `hermes setup` or first-run wizard inside the new containers — they must come
  up pointed at the existing data, not create fresh state.
- **Before stopping anything**, take the backup step in the runbook
  (`ansible-playbook playbooks/backup.yml`). This is your actual safety net for
  "everything" — if the live cutover goes wrong, this is how state gets back.
  Confirm the backup file lands in `backups/` and is non-trivial in size before
  proceeding past it.

## Precondition found and NOT yet fixed — fix this FIRST
`manifests/hermes/compose.yml` requires `API_SERVER_KEY` to be set:
```
API_SERVER_KEY=${API_SERVER_KEY:?set API_SERVER_KEY in .env}
```
This is the bearer-token auth for Hermes's internal API server on port 8642
(not published outside the container — this key is defense-in-depth, not
something anything external needs to know yet). The real env file the Ansible
role reads is `/etc/personal-agent-infra.env` (per `ansible/inventory.yml`'s
`runtime_env` var) — **confirmed this session that this file currently has NO
`API_SERVER_KEY` entry.** Without it, `docker compose up` for the hermes
project will fail immediately with the `:?` error.

**Fix:** generate a random key (`openssl rand -hex 32` is fine) and add
`API_SERVER_KEY=<value>` to `/etc/personal-agent-infra.env` as root, before
running the real cutover. Do this as part of step 1/2 of the runbook, not
silently — tell William what you did (not the key value itself, just that you
set it) in your final report.

## Everything else
Follow `docs/vps-docker-cutover-runbook.md` exactly as written — it already
covers: dry-run (`--check --diff`) first, backup, stop old units, run the real
`--tags hermes,paseo` play, verify containers are healthy, functional check
from a real client (Telegram message or dashboard), rollback path if broken.

## Known unverified risks (carried from prior review, still unresolved)
- `HERMES_UID`/`HERMES_GID` env vars — whether the image's entrypoint actually
  honors them is unverified. Watch container logs closely on first start.
- Paseo's healthcheck assumes `bash` exists inside its image — unverified.
- Container UID `1003:1003` forced for paseo bind-mount ownership — untested.

## Report back (required, before William acts on your output)
- Exact commands run, in order.
- Output of the dry run.
- Confirmation the backup file exists with its size.
- Output of starting the real containers (docker ps, docker logs excerpts).
- Result of the functional check (did Hermes respond via Telegram/dashboard
  with the same conversation history visible as before cutover — this is the
  actual proof "everything" was retained, not just a config diff).
- Any step where something didn't match the runbook's expectation — stop and
  report rather than guessing past it.
- Do NOT git push without a separate explicit go-ahead (push is unrelated to
  this task; you were only elevated for live systemctl/docker operations).
