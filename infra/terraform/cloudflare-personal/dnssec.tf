// DNSSEC end-to-end for the 3 personal zones:
//   1. cloudflare_zone_dnssec: CF generates KSK + signs the zone
//   2. aws_route53domains_delegation_signer_record: publishes the DS
//      record at the registrar (Route53 Domains) so the parent .net /
//      .com zone validates the chain
//
// Single TF apply covers both sides — no manual UI step.

locals {
  personal_zones = {
    grahamsmith   = "grahamsmith.net"
    smithforsb    = "smithforsb.com"
    stopthecastle = "stopthecastle.com"
  }
}

resource "cloudflare_zone_dnssec" "grahamsmith" {
  zone_id = var.grahamsmith_zone_id
}

resource "cloudflare_zone_dnssec" "smithforsb" {
  zone_id = var.smithforsb_zone_id
}

resource "cloudflare_zone_dnssec" "stopthecastle" {
  zone_id = var.stopthecastle_zone_id
}

resource "aws_route53domains_delegation_signer_record" "grahamsmith" {
  domain_name = local.personal_zones.grahamsmith
  signing_attributes {
    algorithm  = tonumber(cloudflare_zone_dnssec.grahamsmith.algorithm)
    flags      = cloudflare_zone_dnssec.grahamsmith.flags
    public_key = cloudflare_zone_dnssec.grahamsmith.public_key
  }
}

resource "aws_route53domains_delegation_signer_record" "smithforsb" {
  domain_name = local.personal_zones.smithforsb
  signing_attributes {
    algorithm  = tonumber(cloudflare_zone_dnssec.smithforsb.algorithm)
    flags      = cloudflare_zone_dnssec.smithforsb.flags
    public_key = cloudflare_zone_dnssec.smithforsb.public_key
  }
}

resource "aws_route53domains_delegation_signer_record" "stopthecastle" {
  domain_name = local.personal_zones.stopthecastle
  signing_attributes {
    algorithm  = tonumber(cloudflare_zone_dnssec.stopthecastle.algorithm)
    flags      = cloudflare_zone_dnssec.stopthecastle.flags
    public_key = cloudflare_zone_dnssec.stopthecastle.public_key
  }
}
