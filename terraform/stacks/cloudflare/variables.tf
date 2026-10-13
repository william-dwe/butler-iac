variable "zone_name" {
  description = "DNS zone managed by this stack."
  type        = string
  default     = "williamwibowo.com"
}

variable "tailscale_ip" {
  description = "This host's Tailscale IPv4. Private *.zone names resolve to it. Supplied as TF_VAR_tailscale_ip by scripts/terraform.sh; never committed."
  type        = string

  validation {
    condition     = can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}$", var.tailscale_ip))
    error_message = "tailscale_ip must be in Tailscale's 100.64.0.0/10 range."
  }
}
