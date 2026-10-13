output "record_ids" {
  description = "Record IDs by key."
  value       = { for k, r in cloudflare_dns_record.this : k => r.id }
}
