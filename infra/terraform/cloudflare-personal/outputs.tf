// DNSSEC values for each zone. The registrar (AWS Route53 Domains)
// takes the PUBLIC KEY (not the digest) when adding a DS record via UI;
// the DS record itself is for parent zones that accept the DS form.
//
// Full IaC of the registrar side happens in dnssec.tf via
// aws_route53domains_delegation_signer_record — these outputs exist
// for visibility and as a manual fallback.
//
// Retrieve with: terraform output -json dnssec
output "dnssec" {
  description = "DNSSEC key + DS values per zone."
  value = {
    for name, r in {
      grahamsmith   = cloudflare_zone_dnssec.grahamsmith
      smithforsb    = cloudflare_zone_dnssec.smithforsb
      stopthecastle = cloudflare_zone_dnssec.stopthecastle
      } : name => {
      key_tag     = r.key_tag
      algorithm   = r.algorithm    # 13 = ECDSAP256SHA256
      flags       = r.flags        # 257 = KSK
      key_type    = r.key_type     # ECDSAP256SHA256
      public_key  = r.public_key   # what Route53 Domains UI wants
      digest_type = r.digest_type  # 2 = SHA-256
      digest      = r.digest       # what the DS record contains
      ds          = r.ds           # full DS RR
    }
  }
}
