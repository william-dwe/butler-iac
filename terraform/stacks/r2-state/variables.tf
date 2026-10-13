variable "account_id" {
  description = "Cloudflare account ID that owns the bucket. Supplied as TF_VAR_account_id by scripts/terraform.sh."
  type        = string
}

variable "bucket_name" {
  description = "R2 bucket holding Terraform state for the other stacks (must match backend.tf there)."
  type        = string
  default     = "butler-iac-tfstate"
}
