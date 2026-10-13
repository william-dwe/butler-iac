# Needs a CLOUDFLARE_API_TOKEN with Account > Workers R2 Storage > Edit (the DNS token is not enough).
# Chicken-and-egg: this stack creates the bucket the other stacks keep their state in, so it uses LOCAL state
# (git-ignored terraform.tfstate). If that file is lost, `terraform import` the bucket: see terraform/README.md.
provider "cloudflare" {}
