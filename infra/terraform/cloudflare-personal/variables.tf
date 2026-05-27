// Cloudflare zones for personal/forwarding-only domains.
//
// All three are migrated off Route53 ($0.50/mo per zone × 3 = $1.50/mo).
// Each was previously in Route53 with active SES mail forwarding + (for
// the .com domains) CloudFront-fronted static sites. The migration
// preserves all SES records, ACM validation CNAMEs (so cert auto-renewal
// continues), and the apex CNAME-flat → CloudFront.
//
// Records dropped: autodiscover.* (Outlook autodiscover, no longer used);
// for grahamsmith.net: vpn.*, windtryst.* (migrated away).
//
// CF zone IDs are populated after manual zone creation in the CF
// dashboard ("Add a site"). Pass via TF_VAR_*_zone_id or fill in
// terraform.auto.tfvars (gitignored).

variable "cloudflare_account_id" {
  description = "CF account ID (same account that owns etherport.net)."
  type        = string
}

variable "grahamsmith_zone_id" {
  description = "Zone ID for grahamsmith.net (CF Free)."
  type        = string
}

variable "smithforsb_zone_id" {
  description = "Zone ID for smithforsb.com (CF Free)."
  type        = string
}

variable "stopthecastle_zone_id" {
  description = "Zone ID for stopthecastle.com (CF Free)."
  type        = string
}
