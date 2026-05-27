// DNSSEC for the 3 personal zones. CF generates the signing keys + a
// DS record per zone; the DS record must be published at the
// REGISTRAR for the parent (.net / .com) zone to chain trust.
//
// Where to publish each DS record:
//   grahamsmith.net   → Route53 Domains (AWS Console)
//   smithforsb.com    → Route53 Domains (AWS Console)
//   stopthecastle.com → Route53 Domains (AWS Console)
//
// Run `terraform output dnssec_ds` after apply to get all the DS values
// in one shot for the registrar console.

resource "cloudflare_zone_dnssec" "grahamsmith" {
  zone_id = var.grahamsmith_zone_id
}

resource "cloudflare_zone_dnssec" "smithforsb" {
  zone_id = var.smithforsb_zone_id
}

resource "cloudflare_zone_dnssec" "stopthecastle" {
  zone_id = var.stopthecastle_zone_id
}
