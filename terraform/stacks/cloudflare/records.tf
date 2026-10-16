locals {
  # Private tier: unreachable outside the tailnet, so DNS-only (Cloudflare's proxy cannot reach a 100.x address).
  private_records = {
    wildcard = { type = "A", name = "*", content = var.tailscale_ip, ttl = 300, comment = "Private services (Caddy, tailnet only)" }
  }

  # Website, served by Caddy on this VPS (manifests/portfolio). Proxied: Cloudflare terminates TLS for visitors and
  # connects to Caddy on 443 (SSL/TLS mode Full or Full (strict)); UFW admits only Cloudflare's ranges.
  # Rollback to Netlify: apex A 75.2.60.5 and www CNAME incomparable-donut-afc15b.netlify.app, both proxied.
  web_records = {
    apex = { type = "A", name = "@", content = var.public_ip, proxied = true }
    www  = { type = "CNAME", name = "www", content = var.zone_name, proxied = true }
  }

  # Mail: Squarespace forwarding (Mailgun MX) and Gmail send-as. One SPF record only.
  mail_records = {
    mx_a = { type = "MX", name = "@", content = "mxa.mailgun.org", priority = 10 }
    mx_b = { type = "MX", name = "@", content = "mxb.mailgun.org", priority = 10 }
    spf  = { type = "TXT", name = "@", content = "\"v=spf1 include:mailgun.org include:_spf.google.com ~all\"" }
    dkim = { type = "TXT", name = "pic._domainkey", content = "\"k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDD8lfm2VvSlms3ax+0vRIZjaF2D67a98b+FyoieBT6Xu3iJdmzyw89+QpoBIW6kdD1nT40qmg5nRZaJsHuHZspmlGPf1HZ73TUKgO/GMGBWSGo82MVcTZOdHd7e+JT+WRhh1buAs+FjegU5DRVk9l6YA0IjT1QQ2q4qssft/zHFQIDAQAB\"" }
  }

  # Left over from the Squarespace domain; harmless, kept so state matches the zone.
  legacy_records = {
    domainconnect = { type = "CNAME", name = "_domainconnect", content = "_domainconnect.domains.squarespace.com", proxied = true }
  }

  records = merge(local.private_records, local.web_records, local.mail_records, local.legacy_records)
}
