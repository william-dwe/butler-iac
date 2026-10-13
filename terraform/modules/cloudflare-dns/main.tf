locals {
  fqdn = { for k, r in var.records : k => r.name == "@" ? var.zone_name : "${r.name}.${var.zone_name}" }
}

resource "cloudflare_dns_record" "this" {
  for_each = var.records

  zone_id  = var.zone_id
  name     = local.fqdn[each.key]
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
  comment  = each.value.comment
}
