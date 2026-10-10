# butler-iac

GitOps manifest repo for personal-agent-infra Docker image digests. The `agentops`
system account (on the VPS, created by the `common` Ansible role) commits digest
bumps here after checking upstream registries for new builds of the pinned images.

A separate systemd timer (running as `ubuntu`, who owns the docker group) pulls this
repo and runs `docker compose pull && up -d` for each manifest. agentops never has
docker-group access itself -- it only writes manifest files; ubnotu applies them.

## Layout
- `manifests/<service>/compose.yml` -- one file per auto-deployed service.
- Image references use `@sha256:...` digests, never `:latest` tags, so a bump is a
  real, auditable file diff.

## Scope
Only butler-backend and butler-frontend are pulled from Williams private GCR; every
other image here is a public upstream vendor image (nousresearch/hermes-agent,
ghcr.io/getpaseo/paseo, prom/*, grafana/grafana, gcr.io/cadvisor/cadvisor).

9router and headroom are intentionally NOT managed here -- pinned manually, out of
scope for GitOps auto-deploy per project decision.
