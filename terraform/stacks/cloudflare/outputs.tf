output "zone_id" {
  value = data.cloudflare_zone.this.zone_id
}

output "record_ids" {
  value = module.dns.record_ids
}
