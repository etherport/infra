variable "aws_profile" {
  description = "AWS profile to use for S3 backend (empty string for environment variables in CI)"
  type        = string
  default     = "homelab"
}

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint URL"
  type        = string
  default     = "https://pve.wind.etherport.net:8006/api2/json"
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID, e.g. graham@pam!terraform"
  type        = string
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Proxmox node to firewall (host management plane)"
  type        = string
  default     = "pve"
}

# Trusted admin source ranges allowed to reach the PVE host management plane
# (API 8006 / SSH 22 / SPICE / ping). Deliberately covers every path admin
# access can arrive by — see H37 / zero-trust-assessment-2026-06-17.md:
#   10.10.200.0/24  Management VLAN (local)
#   10.10.201.0/24  Servers — WG-pod SNAT source + likely TS subnet-router
#   10.10.202.0/24  Mac mini LAN (10.10.202.101)
#   100.64.0.0/10   Tailscale CGNAT (if PVE is reached as a tailnet node)
#   10.254.0.0/24   WireGuard client tunnel (wg1) — if not SNAT'd
#   10.255.255.0/29 WireGuard site tunnel (wg0) — if not SNAT'd
#   192.168.3.0/24  UDM backup WireGuard (WireGuard WAN1) — the OUT-OF-BAND
#                   break-glass that terminates on the UDM itself, independent
#                   of the host's VMs/pods. UDM routes (no SNAT) so PVE sees the
#                   192.168.3.x client IP. MUST stay allowed — it's our last way
#                   in if the host's WG-pod / TS-subnet-routers (both VMs) die.
# Stage 1 is permissive (input policy ACCEPT) so this denies nothing yet; we
# observe logs to pin the real SNAT sources before the Stage 2 DROP flip.
variable "mgmt_admin_cidrs" {
  description = "Trusted admin source CIDRs for the PVE host management plane"
  type        = list(string)
  default = [
    "10.10.200.0/24",
    "10.10.201.0/24",
    "10.10.202.0/24",
    "100.64.0.0/10",
    "10.254.0.0/24",
    "10.255.255.0/29",
    "192.168.3.0/24",
  ]
}

# Dedicated Ceph storage VLAN (vmbr0.210). The host runs the Ceph mon+OSDs here
# (10.10.210.41) and the K8s nodes are RBD clients on the same /24. The host
# firewall must allow this VLAN to the Ceph daemon ports or NEW rbd map/create
# from K8s is dropped under the Stage-2 DROP policy (H37 oversight fixed 2026-06-18).
variable "ceph_storage_cidr" {
  description = "Dedicated Ceph storage VLAN CIDR allowed to reach the host's Ceph mon/OSD ports"
  type        = string
  default     = "10.10.210.0/24"
}

# Source allowed to scrape the host's in-band ipmi_exporter (:9290). Prometheus
# runs in K8s; pod->host traffic is Cilium-masqueraded to the node IP, so the
# source is the Servers/K8s VLAN. Without this the Stage-2 DROP policy drops the
# scrape -> TargetDown 'pve-ipmi' (H37 oversight fixed 2026-06-20).
variable "ipmi_scrape_cidr" {
  description = "CIDR (K8s/Servers VLAN) allowed to scrape the host's ipmi_exporter :9290"
  type        = string
  default     = "10.10.201.0/24"
}
