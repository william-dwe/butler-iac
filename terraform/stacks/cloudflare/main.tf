data "cloudflare_zone" "this" {
  filter = {
    name = var.zone_name
  }
}

module "dns" {
  source = "../../modules/cloudflare-dns"

  zone_id   = data.cloudflare_zone.this.zone_id
  zone_name = var.zone_name
  records   = local.records
}
