resource "cloudflare_r2_bucket" "tfstate" {
  account_id = var.account_id
  name       = var.bucket_name

  lifecycle {
    prevent_destroy = true # losing this bucket loses every stack's state
  }
}
