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
}
