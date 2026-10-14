# Terraform

Infrastructure outside the VPS itself. Ansible configures the host; Terraform manages third-party resources.

## Layout

```
terraform/
├── modules/                 reusable, provider-scoped building blocks (no backend, no provider config)
│   └── cloudflare-dns/      cloudflare_dns_record for_each over a map of records
└── stacks/                  one root module per provider/concern, each with its own state key
    ├── r2-state/            the R2 bucket that holds every stack's state, its own included (key r2-state/)
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

Always through the wrapper. It loads `CLOUDFLARE_TERRAFORM_TOKEN` (falls back to `CLOUDFLARE_API_TOKEN`) and the R2 credentials from `stack.env` and sets
`TF_VAR_tailscale_ip` from `tailscale ip -4`, so no IP or secret is committed:

```bash
scripts/terraform.sh cloudflare plan -out=/tmp/cf.plan
scripts/terraform.sh cloudflare apply /tmp/cf.plan     # apply the reviewed plan file, never -auto-approve
```

Add a record: edit `stacks/cloudflare/records.tf`, plan, review, apply. Private services need no record, the wildcard covers
`*.williamwibowo.com` and points at the Tailscale IP. A public site needs its own record (keep the Caddy block's `bind` in step).
Records stay DNS-only unless they are public: Cloudflare's proxy cannot reach a `100.x` address.

## State backend: Cloudflare R2 (one-time setup)

`stacks/cloudflare` is configured for an R2 bucket (`backend.tf`, S3 API; settings follow Cloudflare's remote-backend
example). The cloudflare stack was migrated to it and verified (a plan reading only from the bucket reported no changes).
`use_lockfile` is on: R2 documents `If-None-Match` support on PutObject, and a test with two simultaneous plans rejected the second with `412 PreconditionFailed`. A crashed run can leave a stale `.tflock` object; clear it with `scripts/terraform.sh <stack> force-unlock <ID>`.
R2 honors the conditional writes it needs is unconfirmed, and there is a single operator.

1. **Bucket.** Create `butler-iac-tfstate` in the dashboard (R2 -> Create bucket). It is then tracked as code by `r2-state`
   (see "Track the bucket as code" below).
2. **S3 keys.** R2 -> Manage API tokens -> create an **Object Read & Write** token scoped to that bucket. Copy the Access Key ID
   and Secret.
3. **Store them** as the administrator, on a trusted terminal (never in chat):
   ```bash
   dotenvx set R2_ACCESS_KEY_ID '...' -f .env
   dotenvx set R2_SECRET_ACCESS_KEY '...' -f .env
   dotenvx set CLOUDFLARE_ACCOUNT_ID '...' -f .env      # dashboard sidebar / R2 overview
   sudo scripts/dotenv-env.sh render && sudo scripts/stack-env.sh
   ```
4. **Migrate** a stack that still has local state (keep `terraform.tfstate` as a backup until verified):
   ```bash
   rm terraform/stacks/cloudflare/backend_override.tf
   scripts/terraform.sh cloudflare init -migrate-state -force-copy
   scripts/terraform.sh cloudflare plan -detailed-exitcode     # exit 0 = state matches
   mv terraform/stacks/cloudflare/terraform.tfstate ~/tfstate-cloudflare.bak   # after verifying
   ```

### Track the bucket as code

`stacks/r2-state` keeps its state in the bucket it manages. Importing needs an R2-capable API token, which `CLOUDFLARE_TERRAFORM_TOKEN` is (the Caddy DNS token and the S3 keys cannot read bucket metadata):

```bash
scripts/terraform.sh r2-state init
scripts/terraform.sh r2-state import cloudflare_r2_bucket.tfstate "<account_id>/butler-iac-tfstate/default"   # id is account/bucket/jurisdiction
scripts/terraform.sh r2-state plan -detailed-exitcode   # 0 = bucket matches the code
```

On a new VPS the bucket already exists, so only `init` is needed.

`CLOUDFLARE_TERRAFORM_TOKEN` needs Zone:Read and DNS:Edit on the zone plus Account -> Workers R2 Storage -> Edit; keep it out of containers. `CLOUDFLARE_API_TOKEN` stays DNS-edit only for Caddy. R2 S3 keys are a third credential.
The wrapper fails with a clear message if a stack uses the R2 backend and the keys are missing.

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
