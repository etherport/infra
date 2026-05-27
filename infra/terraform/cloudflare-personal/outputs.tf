// DNSSEC DS records to publish at each domain's registrar
// (AWS Route53 Domains). Without the DS record at the parent, the
// zone is signed but resolvers won't validate the chain.
//
// Retrieve with: terraform output -json dnssec_ds
output "dnssec_ds" {
  description = "DNSSEC DS record values for each zone — publish at the registrar."
  value = {
    grahamsmith = {
      key_tag     = cloudflare_zone_dnssec.grahamsmith.key_tag
      algorithm   = cloudflare_zone_dnssec.grahamsmith.algorithm
      digest_type = cloudflare_zone_dnssec.grahamsmith.digest_type
      digest      = cloudflare_zone_dnssec.grahamsmith.digest
      ds          = cloudflare_zone_dnssec.grahamsmith.ds
    }
    smithforsb = {
      key_tag     = cloudflare_zone_dnssec.smithforsb.key_tag
      algorithm   = cloudflare_zone_dnssec.smithforsb.algorithm
      digest_type = cloudflare_zone_dnssec.smithforsb.digest_type
      digest      = cloudflare_zone_dnssec.smithforsb.digest
      ds          = cloudflare_zone_dnssec.smithforsb.ds
    }
    stopthecastle = {
      key_tag     = cloudflare_zone_dnssec.stopthecastle.key_tag
      algorithm   = cloudflare_zone_dnssec.stopthecastle.algorithm
      digest_type = cloudflare_zone_dnssec.stopthecastle.digest_type
      digest      = cloudflare_zone_dnssec.stopthecastle.digest
      ds          = cloudflare_zone_dnssec.stopthecastle.ds
    }
  }
}
