# BGP migration — Phase A: add the VLAN 209 (vsan) node interface

**Part of:** `docs/planning/metallb-bgp-migration-2026-05-29.md` (M18/M36).
**Goal:** give the NAS-workload nodes a direct L2 interface on VLAN 209 (the `vsan` SDN VNet) so kubelet NFS mounts to `sequoia` (10.10.209.10) stay on the switch fabric — *before* Servers/201 moves to UDM-routed in Phase B. This phase is **purely additive** (no routing change) so it cannot disrupt anything; it just adds a faster path.

**Scope:** workers `w1-w4` + `gpu1` (untracked/untainted — they run the NAS workloads: Plex, s3-sync ×7, rclone). **NOT control planes** (tainted NoSchedule → no NAS workloads → don't need it).

**Prereqs (already true):** the `vsan` SDN VNet (tag 209) exists + is healthy on the PVE host (`bridge vsan UP`, enslaving `vmbr0.209`, no host IP → conflict-free). Verified 2026-05-29.

---

## Step 1 — TF: append a `vsan` vNIC (net5) to workers + gpu1

In `infra/terraform/proxmox/k8s-vms/main.tf`, append this block **after the existing VLAN 210 `network_device`** in BOTH the `workers` resource (after line ~268) and the `k8s_gpu1` resource (after line ~391). **Append at the end — inserting earlier renumbers net4/Ceph and is disruptive.**

```hcl
  # NAS/storage VLAN 209 — direct L2 path to the UNAS (sequoia
  # 10.10.209.10) so kubelet NFS mounts (Plex media, s3-sync, rclone)
  # stay on the switch fabric instead of routing through the UDM after
  # Servers/201 becomes UDM-routed (M18 BGP migration, Phase B). Uses the
  # `vsan` SDN VNet (tag 209) — NOT raw vmbr0+tag like the Ceph 210 NIC,
  # because 209 has no PVE-host IP so the SDN VNet is conflict-free.
  # DHCP reservation + netplan bring-up via k8s-node-fixes.yml (mirrors 210).
  network_device {
    bridge = "vsan"
    model  = "virtio"
    mtu    = 9000
  }
```

Do **not** add it to the `control_plane` resource.

**Apply:** `terraform plan` first and confirm it's an **in-place update** (add NIC), NOT a VM recreate (bpg/proxmox treats `network_device` as updatable → in-place hot-plug; if plan shows `-/+` recreate, STOP). Apply during a low-use window; the NIC hot-plugs to each running VM with no node disruption (the guest ignores it until Step 3).

## Step 2 — DHCP reservations for the new NICs

The vsan NIC gets its IP via DHCP reservation (same model as the Ceph 210 NIC), MAC→`10.10.209.5x`:

1. After Step 1 applies, read each new NIC's MAC: `qm config <vmid> | grep net5` on the PVE host (or the bpg TF state).
2. Add a UniFi DHCP reservation per node mapping that MAC → a `10.10.209.5x` address (suggest matching the last octet to the node's 201/210 IP: w1=.53, w2=.54, w3=.55, w4=.56, gpu1=.60). Codify in `infra/terraform/unifi/reservations.tf` (where the other reservations live).

## Step 3 — netplan: bring up the 209 NIC (DHCP, MTU 9000)

In `infra/ansible/playbooks/k8s-node-fixes.yml`, extend the netplan task that already configures the Ceph (enp6s22/210) NIC to also configure the new 209 interface (it'll enumerate as the next ethN / by-MAC). DHCP on, MTU 9000, no default route (the 201 NIC keeps the default route). Run via the `ansible-proxmox`/node-fixes workflow against w1-4 + gpu1.

Verify the node has a connected route to `10.10.209.0/24` on the new NIC:
```
ip route get 10.10.209.10   # should egress the 209 NIC, not the 201 gateway
```

## Step 4 — re-path the NAS workloads + verify

The kubelet mounts NFS at pod-start, so existing mounts won't move until the pods restart:
1. `kubectl rollout restart deploy/plex -n plex` (+ any long-running NAS consumers); CronJobs (s3-sync, rclone) pick it up on their next run.
2. On the node running Plex, confirm the NFS traffic to 10.10.209.10 egresses the 209 NIC (`ss -tn dst 10.10.209.10` + check the route).
3. Sanity: Plex still plays media; an s3-sync run completes; Ceph + cluster health unchanged.

**This phase changes no routing**, so rollback is just removing the NIC block (TF) + netplan stanza — but there's no reason to: it's a strictly-additive faster path. Phase B (Servers/201 → UDM-routed) depends on this being in place.

---

## Why this is safe to apply incrementally
- No routing change in Phase A — the 201 path is untouched; NAS still works exactly as today until the 209 NIC is up, then it just gets faster/more-direct.
- Can be done one node at a time (drain optional — hot-plug doesn't require it).
- The risky routing move (Phase B) is gated behind this completing + verifying.
