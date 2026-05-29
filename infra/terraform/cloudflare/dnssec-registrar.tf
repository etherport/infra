// Registrar-side DS publication for etherport.net. CF generates the
// KSK + signs the zone (cloudflare_zone_dnssec.etherport in main.tf);
// this resource pushes the corresponding DS record up to the AWS
// Route53 Domains registrar so resolvers can validate the chain.
//
// aws_route53domains_delegation_signer_record is the registrar-side
// (parent zone) DS record. It's distinct from aws_route53_key_signing_key
// which would only matter if Route53 were also the authoritative DNS
// (it's not — CF is).
resource "aws_route53domains_delegation_signer_record" "etherport" {
  domain_name = var.cf_zone_domain

  signing_attributes {
    algorithm  = tonumber(cloudflare_zone_dnssec.etherport.algorithm)
    flags      = cloudflare_zone_dnssec.etherport.flags
    public_key = cloudflare_zone_dnssec.etherport.public_key
  }

  # On import the AWS API doesn't return signing_attributes in a form that
  # round-trips against the CF-sourced values, so TF wants to destroy+
  # recreate the DS record on every plan — which would briefly break the
  # DNSSEC chain of trust at the registrar. The DS is already live + correct
  # at Route53 Domains (algo 13, keyTag 2371); ignore attribute drift so the
  # imported resource stays put. Re-import if the CF KSK is ever rotated.
  lifecycle {
    ignore_changes = [signing_attributes]
  }
}
