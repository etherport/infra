# Kubernetes Node VLAN Interface Configuration

> **This page has been superseded.** As of 2026-05-12 the VLAN parent
> interfaces are baked into the Packer template and managed by netplan,
> not by the manual `systemd-networkd` snippets that used to live here.
> Use the dedicated runbook and Multus README instead — this page is
> kept as a short quick-reference.
>
> Primary references:
> - **Netplan recovery / emergency manual setup:**
>   [`docs/runbooks/vlan-interfaces-netplan.md`](../runbooks/vlan-interfaces-netplan.md)
> - **Multus NADs and VLAN architecture:**
>   [`platform/kubernetes/multus/README.md`](../../platform/kubernetes/multus/README.md)

## Quick Reference

All K8s nodes have six interfaces. The first is configured by cloud-init
(VLAN 201 management); three are VLAN parents for Multus; two are
storage interfaces (Ceph 210 + backup/NAS 209). The Multus VLAN parents
are brought up by `/etc/netplan/51-vlan-interfaces.yaml` (baked into the
Packer-built template VM 9001); the storage interfaces are brought up by
`/etc/netplan/52-storage.yaml` and use DHCP-without-routes-or-DNS to
avoid polluting the cluster-network routing table (post-2026-05-18).
(Control-plane nodes omit `enp6s23` — VLAN 209 lands on workers + GPU only.)

| Interface | VLAN | Network | Purpose |
|-----------|------|---------|---------|
| eth0 (enp6s18) | 201 | 10.10.201.0/24 | Management (cluster, kubelet, API) |
| enp6s19 | 202 | 10.10.202.0/24 | Client devices |
| enp6s20 | 204 | 10.10.204.0/24 | IoT devices |
| enp6s21 | 205 | 10.10.205.0/24 | Security devices (cameras, etc.) |
| enp6s22 | 210 | 10.10.210.0/24 | Storage (Ceph, MTU 9000) |
| enp6s23 | 209 | 10.10.209.0/24 | Backup / NAS storage (workers + GPU) |

## Node IP Assignments (VLAN 201 — management)

3 CP HA + 4 workers + 1 GPU:

| Node | VLAN 201 |
|------|----------|
| k8s-cp1 | 10.10.201.50 |
| k8s-cp2 | 10.10.201.51 |
| k8s-cp3 | 10.10.201.52 |
| k8s-w1 | 10.10.201.53 |
| k8s-w2 | 10.10.201.54 |
| k8s-w3 | 10.10.201.55 |
| k8s-w4 | 10.10.201.56 |
| k8s-gpu1 | 10.10.201.60 |

The VLAN 202/204/205 parents do **not** carry an L3 IP on the node — they
are pure carriers for Multus macvlan attachments. Per-pod IPs are issued
by the NADs in `platform/kubernetes/multus/network-attachment-definitions/`.

## Verification

```bash
# All parents should be 'state UP' (no address required)
ip -br link show enp6s19 enp6s20 enp6s21

# The netplan stanza that brings them up:
cat /etc/netplan/51-vlan-interfaces.yaml
```

If a node is missing the netplan file (e.g., not yet rebuilt from the
current template), run the recovery from
[`vlan-interfaces-netplan.md`](../runbooks/vlan-interfaces-netplan.md) or
the ansible task at
`infra/ansible/playbooks/k8s-node-fixes.yml`
(`Ensure VLAN parent interfaces are UP via netplan`).
