variable "zone_id" {
  description = "Cloudflare zone ID that owns the records."
  type        = string
}

variable "zone_name" {
  description = "Zone apex, e.g. example.com. Record names are relative to it (\"@\" is the apex)."
  type        = string
}

variable "records" {
  description = "DNS records keyed by a stable label (changing a key recreates the record)."
  type = map(object({
    type     = string
    name     = string
    content  = string
    ttl      = optional(number, 1) # 1 = automatic
    proxied  = optional(bool, false)
    priority = optional(number)
    comment  = optional(string)
  }))
}
