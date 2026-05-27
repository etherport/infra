output "tunnel_id" {
  description = "Tunnel ID — used in the CNAME target (<id>.cfargotunnel.com)"
  value       = cloudflare_tunnel.wind_cluster.id
}

output "tunnel_token" {
  description = <<-EOT
    Base64-encoded TUNNEL_TOKEN for cloudflared. Feed this into the
    platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml secret.
    Retrieve with: terraform output -raw tunnel_token | pbcopy
  EOT
  value       = cloudflare_tunnel.wind_cluster.tunnel_token
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

output "etherport_dnssec_ds" {
  description = <<-EOT
    DNSSEC DS record values to publish at the etherport.net registrar
    (AWS Route53 Domains). Without this DS record, the zone is signed
    but the chain isn't validated by resolvers.
      key_tag, algorithm, digest_type, digest
    Set them in: AWS Console -> Route53 -> Registered domains ->
    etherport.net -> DNSSEC status -> Add key.
  EOT
  value = {
    key_tag      = cloudflare_zone_dnssec.etherport.key_tag
    algorithm    = cloudflare_zone_dnssec.etherport.algorithm
    digest_type  = cloudflare_zone_dnssec.etherport.digest_type
    digest       = cloudflare_zone_dnssec.etherport.digest
    ds           = cloudflare_zone_dnssec.etherport.ds
  }
}
