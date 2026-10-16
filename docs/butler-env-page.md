# Butler "Secrets" page (Butler side, owner: agentops)

UI only (ready-made patch: `docs/butler-secrets-page.patch`, apply from the Butler repo root with `git apply`). Same origin as the dashboard (`https://butler.williamwibowo.com`), so no CORS and no new auth. The infra repo serves the API:
Caddy sends `/_env/*` to `scripts/env-set-api.py`, bypassing the Butler backend. Do not add a Butler backend endpoint for this.

## API
- `GET /_env/keys` -> `[{"key": "BROWSER_PASSWORD", "set": false}, ...]`. Names and set/unset only; values are never returned.
- `POST /_env/set` with `Content-Type: application/json` and body `{"key": "...", "value": "..."}` -> `{"ok": true, "message": "..."}`.
  400 bad key/value (key must be in `.env.example`), 403 auth/origin, 500 failure. The `message` never contains the value.

## Page
- Route `/secrets`, behind the same Tailscale-login gate as the rest of the dashboard.
- Key picker (from `/_env/keys`, show a "set" badge), password-type value input (`autocomplete="off"`, no storage), Save button.
- Clear the input after save; show only `message`. Never log, persist or echo the value; no analytics on this page.
- Note on the page: saved keys apply on the next gitops run (<= 1 min); a new key must first be added to `.env.example` in the infra repo.
