# State lives in a Cloudflare R2 bucket through the S3 API. Credentials and the endpoint come from the environment
# (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_ENDPOINT_URL_S3), set by scripts/terraform.sh, so nothing secret is committed.
terraform {
  backend "s3" {
    bucket = "butler-iac-tfstate"
    key    = "cloudflare/terraform.tfstate"
    region = "auto" # R2 ignores the region; the S3 backend just requires a value

    # R2 is not AWS: skip AWS-only account, region and checksum validations.
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
