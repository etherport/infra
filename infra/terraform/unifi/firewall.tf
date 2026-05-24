// UDM firewall rules — paultyng/unifi provider uses the LEGACY
// (non-zone-based) firewall API. UniFi 10+ runs both rulesets in
// parallel, so legacy rules apply alongside the new zone matrix.
//
// First entry here closes the syslog cross-VLAN gap surfaced when
// onboarding UNVR (VLAN 212) + UNAS (VLAN 209) to the Alloy syslog
// receiver at 10.10.201.73 (VLAN 201). Default zone-matrix policies
// block 212→201 and 209→201, so syslog packets never arrive even
// though both devices were configured + reachable.
//
// We use inline src/dst addresses on the rule instead of pre-created
// `unifi_firewall_group` resources because the legacy
// /rest/firewallgroup endpoint rejects address-group creates with
// FirewallGroupInvalidArgs (400) on UniFi 10+ (port-groups still
// work fine; address-groups don't). Inline addresses are simpler and
// avoid the broken endpoint entirely.
//
// rule_index numbers: paultyng/unifi uses an index in the LAN_IN
// chain. Pick numbers above 2000 (well above the auto-generated
// ones) and leave gaps for inserts.

// Port group for UDP/514 — port-groups still work on UniFi 10+ via
// the legacy API, so keep this abstraction for reuse.
resource "unifi_firewall_group" "syslog_port" {
  name    = "syslog-port-514"
  type    = "port-group"
  members = ["514"]
}

// Two rules (one per source IP) instead of one rule + address-group,
// because the legacy address-group endpoint is broken on UniFi 10+.
// Easy to extend: copy the resource, change rule_index + src_address.

resource "unifi_firewall_rule" "allow_syslog_unvr_to_alloy" {
  name                   = "Allow UNVR → Alloy UDP/514 (syslog)"
  action                 = "accept"
  ruleset                = "LAN_IN"
  rule_index             = 2010
  protocol               = "udp"
  src_address            = "10.10.212.10"  // UNVR / Protect controller (VLAN 212)
  dst_address            = "10.10.201.73"  // Alloy MetalLB LB (VLAN 201)
  dst_firewall_group_ids = [unifi_firewall_group.syslog_port.id]
  enabled                = true
  logging                = false
}

resource "unifi_firewall_rule" "allow_syslog_unas_to_alloy" {
  name                   = "Allow UNAS → Alloy UDP/514 (syslog)"
  action                 = "accept"
  ruleset                = "LAN_IN"
  rule_index             = 2011
  protocol               = "udp"
  src_address            = "10.10.209.10"  // UNAS / Sequoia (VLAN 209)
  dst_address            = "10.10.201.73"  // Alloy MetalLB LB (VLAN 201)
  dst_firewall_group_ids = [unifi_firewall_group.syslog_port.id]
  enabled                = true
  logging                = false
}
