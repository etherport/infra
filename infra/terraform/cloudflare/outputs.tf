output "tunnel_id" {
  description = "Tunnel ID — used in the CNAME target (<id>.cfargotunnel.com)"
  value       = cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id
}

# v5: the tunnel token is no longer an attribute on the tunnel resource —
# it's fetched via a dedicated data source.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "wind_cluster" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.wind_cluster.id
}

output "tunnel_token" {
  description = <<-EOT
    Base64-encoded TUNNEL_TOKEN for cloudflared. Feed this into the
    platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml secret.
    Retrieve with: terraform output -raw tunnel_token | pbcopy
  EOT
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.wind_cluster.token
  sensitive   = true
}

output "cf_nameservers" {
  description = <<-EOT
    Cloudflare nameservers for the etherport.net zone. Update etherport.net's
    NS records at the Route53 Registrar (registrar console — NOT the Route53
    hosted zone). After delegation propagates (~5min typical, up to 48h max),
    CF answers all etherport.net queries. This is the destructive cut-over.
  EOT
  value       = cloudflare_zone.etherport.name_servers
}

output "approval_url" {
  description = "Public URL gated by CF Access (used by advisor controller)."
  value       = "https://${var.approval_hostname}/approve"
}

output "zone_id" {
  description = "Zone ID for the etherport.net CF zone — used by future modules / scripts."
  value       = cloudflare_zone.etherport.id
}

output "etherport_dnssec" {
  description = <<-EOT
    DNSSEC key + DS values for etherport.net. Registrar-side delegation
    is IaC'd via aws_route53domains_delegation_signer_record.etherport
    in dnssec-registrar.tf — these outputs exist for visibility.
  EOT
  value = {
    key_tag     = cloudflare_zone_dnssec.etherport.key_tag
    algorithm   = cloudflare_zone_dnssec.etherport.algorithm
    flags       = cloudflare_zone_dnssec.etherport.flags
    key_type    = cloudflare_zone_dnssec.etherport.key_type
    public_key  = cloudflare_zone_dnssec.etherport.public_key
    digest_type = cloudflare_zone_dnssec.etherport.digest_type
    digest      = cloudflare_zone_dnssec.etherport.digest
    ds          = cloudflare_zone_dnssec.etherport.ds
  }
}
