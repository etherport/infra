# One-time TF-state cleanup (safe to delete this file after one successful apply).
#
# unifi_firewall_group.syslog_port:
#   The legacy paultyng-managed syslog port group was migrated to Ansible in
#   commit f228cb1 ("replace broken paultyng TF with Ansible zone-policy IaC").
#   The live group ("syslog-port-514") is now created AND referenced by the
#   Ansible "Allow syslog → Alloy UDP/514" zone-policy rule
#   (infra/ansible/playbooks/udm-firewall.yml), but the resource was left in TF
#   state. A plain `terraform apply` would DESTROY that live group — breaking the
#   Ansible syslog rule that depends on it. Drop it from TF state only; leave the
#   live object alone (Ansible is now its single owner).
removed {
  from = unifi_firewall_group.syslog_port
  lifecycle {
    destroy = false
  }
}
