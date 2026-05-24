// UDM firewall rules — paultyng/unifi provider only supports the
// LEGACY (non-zone-based) firewall API. UniFi 10+ runs both rulesets
// in parallel, so legacy rules apply alongside the new zone matrix.
//
// First entries here close the syslog cross-VLAN gap surfaced when
// onboarding UNVR (VLAN 212) + UNAS (VLAN 209) to the Alloy syslog
// receiver at 10.10.201.73 (VLAN 201). Default zone-matrix policies
// block 212→201 and 209→201, so syslog packets never arrive even
// though both devices were configured + reachable.
//
// rule_index numbers: paultyng/unifi uses an index in the LAN_IN
// chain. Pick numbers above 2000 (well above the auto-generated
// ones) and leave gaps for inserts.

resource "unifi_firewall_group" "syslog_sources" {
  name    = "syslog-sources-unifi-vsan"
  type    = "address-group"
  members = [
    "10.10.212.10/32", // UNVR / Protect controller (VLAN 212 UniFi zone)
    "10.10.209.10/32", // UNAS / Sequoia (VLAN 209 vSAN zone)
  ]
}

resource "unifi_firewall_group" "syslog_dest" {
  name    = "syslog-receiver-alloy"
  type    = "address-group"
  members = [
    "10.10.201.73/32", // Alloy MetalLB LB for syslog (VLAN 201 Servers)
  ]
}

resource "unifi_firewall_group" "syslog_port" {
  name    = "syslog-port-514"
  type    = "port-group"
  members = ["514"]
}

resource "unifi_firewall_rule" "allow_syslog_to_alloy" {
  name = "Allow UNVR+UNAS → Alloy UDP/514 (syslog)"
  // LAN_IN chain governs inter-VLAN traffic that enters the UDM's
  // LAN interface. UDP/514 from the two source addresses to the
  // Alloy LB.
  action          = "accept"
  ruleset         = "LAN_IN"
  rule_index      = 2010
  protocol        = "udp"
  src_firewall_group_ids = [unifi_firewall_group.syslog_sources.id]
  dst_firewall_group_ids = [unifi_firewall_group.syslog_dest.id, unifi_firewall_group.syslog_port.id]
  enabled         = true
  logging         = false
}
