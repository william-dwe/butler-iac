# Terraform

Infrastructure outside the VPS itself. Ansible configures the host; Terraform manages third-party resources.

## Layout

```
terraform/
├── modules/                 reusable, provider-scoped building blocks (no backend, no provider config)
│   └── cloudflare-dns/      cloudflare_dns_record for_each over a map of records
└── stacks/                  one root module per provider/concern, each with its own state key
    └── cloudflare/          zone williamwibowo.com
        ├── versions.tf      Terraform + provider constraints
        ├── backend.tf       R2 (S3 API) backend, credentials from the environment
        ├── providers.tf
        ├── variables.tf
        ├── main.tf          zone lookup + module calls
        ├── records.tf       the records, grouped by purpose (private / web / mail / legacy)
        ├── outputs.tf
        └── .terraform.lock.hcl   committed; pins provider versions and hashes
```

Rules: providers are configured only in `stacks/`, never in `modules/`. A new provider gets its own stack and state key
(`<stack>/terraform.tfstate` in the same bucket), so a mistake in one cannot touch another. State and `.terraform/` are
git-ignored (this repo is public).

## Running

Always through the wrapper. It loads `CLOUDFLARE_API_TOKEN` and the R2 credentials from `stack.env` and sets
`TF_VAR_tailscale_ip` from `tailscale ip -4`, so no IP or secret is committed:

```bash
scripts/terraform.sh cloudflare plan -out=/tmp/cf.plan
scripts/terraform.sh cloudflare apply /tmp/cf.plan     # apply the reviewed plan file, never -auto-approve
```

Add a record: edit `stacks/cloudflare/records.tf`, plan, review, apply. Private services need no record, the wildcard covers
`*.williamwibowo.com` and points at the Tailscale IP. A public site needs its own record (keep the Caddy block's `bind` in step).
Records stay DNS-only unless they are public: Cloudflare's proxy cannot reach a `100.x` address.

## State backend: Cloudflare R2 (one-time setup)

1. Cloudflare dashboard -> R2 -> create bucket `butler-iac-tfstate` (enable object versioning if your plan offers it).
2. R2 -> Manage API tokens -> create an **Object Read & Write** token scoped to that bucket. Copy the Access Key ID and Secret.
3. As the administrator, on a trusted terminal (never in chat):
   ```bash
   dotenvx set R2_ACCESS_KEY_ID '...' -f .env
   dotenvx set R2_SECRET_ACCESS_KEY '...' -f .env
   dotenvx set CLOUDFLARE_ACCOUNT_ID '...' -f .env     # dashboard sidebar / R2 overview
   sudo scripts/dotenv-env.sh render && sudo scripts/stack-env.sh
   ```
4. Migrate the local state: delete `stacks/cloudflare/backend_override.tf` and `terraform.tfstate`'s copy stays as a backup until
   verified, then:
   ```bash
   scripts/terraform.sh cloudflare init -migrate-state
   scripts/terraform.sh cloudflare plan -detailed-exitcode     # exit 0 = state matches
   ```

The API token used by Terraform needs Zone:Read and DNS:Edit on the zone. The R2 keys are a separate credential.

## Rebuilding after losing state

State is a map from code to real resources and is not derivable from Cloudflare. If it is lost, import each record
(`terraform import 'module.dns.cloudflare_dns_record.this["apex"]' <zone_id>/<record_id>`; list ids with the Cloudflare API),
then `plan` must show no changes. With the R2 backend there is nothing to move when the VPS changes: the new host uses the
same bucket and keys. After a move, run `plan`/`apply` once so the wildcard follows the new Tailscale IP.

## Not managed here

- **Google OAuth client** (Butler login): Terraform has no resource for a standard "Sign in with Google" web client or its
  redirect URIs (`google_iam_oauth_client` is for Workforce Identity Federation; the IAP OAuth Admin API behind
  `google_iap_client` is shut down). Redirect URIs are edited in the Google Cloud console.
- Squarespace registrar settings (nameservers), Netlify.
