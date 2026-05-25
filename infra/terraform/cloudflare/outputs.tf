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
    Cloudflare nameservers for the wind.etherport.net zone. Add these as NS
    records on `wind.etherport.net` inside the etherport.net Route53 zone
    to delegate the subdomain to Cloudflare. After delegation propagates,
    CF answers all *.wind.etherport.net queries.
  EOT
  value       = cloudflare_zone.wind.name_servers
}

output "approval_url" {
  description = "Public URL gated by CF Access (used by advisor controller)."
  value       = "https://${var.approval_hostname}/approve"
}
