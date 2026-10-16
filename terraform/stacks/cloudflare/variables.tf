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

variable "public_ip" {
  description = "This host's public IPv4 (the address the cloud provider NATs to it). The proxied website records point at it. Supplied as TF_VAR_public_ip by scripts/terraform.sh from PUBLIC_IP in stack.env; never committed."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.public_ip)) && !can(regex("^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)", var.public_ip))
    error_message = "public_ip must be a public IPv4 address (not private, loopback or Tailscale)."
  }
}
