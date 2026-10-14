# This stack manages the bucket that holds its own state (key r2-state/...). The bucket was created first, then imported
# (terraform/README.md), so there is no chicken-and-egg problem. prevent_destroy guards the bucket.
terraform {
  backend "s3" {
    bucket = "butler-iac-tfstate"
    key    = "r2-state/terraform.tfstate"
    region = "auto" # R2 ignores the region; the S3 backend just requires a value

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
