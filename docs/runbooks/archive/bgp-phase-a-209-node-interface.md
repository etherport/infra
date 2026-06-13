# BGP migration — Phase A: add the VLAN 209 (vsan) node interface

> ## ✅ COMPLETE 2026-05-29 (second pass) — outcome + the one thing the original plan missed
> All 5 nodes (w1–w4 + gpu1) carry the 209 NIC and route to the NAS over it.
> **Actual per-node 209 IPs (DHCP, NOT the `.5x` originally suggested below): w1=10.10.209.100, w2=.101, w3=.102, w4=.103, gpu1=.104.** `ip route get 10.10.209.10` egresses `enp6s23` on every node. Cluster stayed 8/8 Ready, CNPG 3/3 throughout (clean failovers across the rolling drains). A final `terraform plan` shows only the pre-existing benign `watchdog action none→reset` cosmetic drift — zero `network_device` drift.
>
> ### ⚠️ THE MISS: NFS export ACLs key on SOURCE IP — this phase was NOT "purely additive"
> The original plan (and the §below) called adding the 209 path "purely additive — it cannot disrupt anything." **That was wrong.** The UNAS (`sequoia`, 10.10.209.10) exports each NFS share to an **explicit per-host allow-list of the nodes' 201 IPs** (`10.10.201.50–.60`). Once a node has a directly-connected 209 interface, its route to `10.10.209.10` prefers 209, so NFS mounts now arrive from the node's **209** source IP — which was **not** on any allow-list → `mount.nfs: access denied by server`. Plex (the only live in-tree `nfs:` consumer) rescheduled onto rebooted gpu1 and could not mount until this was fixed.
>
> **Fix (applied 2026-05-29):** added the five node 209 IPs (`10.10.209.100–.104`) to **all 9** UNAS NFS shares (Media, Mark, Backups, Scans, Graham, Temp, Content, Archive, Proxmox), *alongside* the existing 201 entries (additive — 201 access preserved). This is **UNAS-UI state, NOT in Terraform/Ansible** — there is no IaC path to UNAS share config today. **On any cluster/NAS rebuild this ACL MUST be re-applied** (both the 201 and 209 IPs). If you ever codify it, the only route is scripting the UniFi/UNAS API.
>
> **Lesson:** "additive network path" ≠ "no behavioural change" when a downstream server authorizes by source IP (NFS exports, firewall rules, DB `pg_hba`, API allow-lists all do this). Always ask "does anything downstream key on the source address?" before assuming a new path is free.
>
> ---

> ## ⚠️ FAILED FIRST ATTEMPT 2026-05-29 — read before retrying
> First attempt (TF apply of the net5 NIC to w1) **hung the node + deadlocked the PVE lock**. Root cause + the corrected procedure:
> 1. **`networkd-wait-online` hang.** w1 rebooted (the bpg apply reboots via graceful `qmshutdown` to apply a NIC change) with the new `enp6s23` present but **no netplan stanza** — so `networkd-wait-online` blocked `network-online.target` on the unconfigured interface and did **not** time out. kubelet/sshd/guest-agent never started → node `NotReady` indefinitely (primary 201 IP was still pingable — it's a boot-service hang, not a network break).
> 2. **Lock deadlock.** Because the guest was hung, it couldn't ACPI-shutdown, so the bpg `qmshutdown` task wedged holding `/var/lock/qemu-server/lock-110.conf`. Cancelling the GH run did NOT release it (the PVE-side task survives the TF client). Recovery required: `kill <qmshutdown task PID>` on PVE → `qm unlock` → `qm set 110 --delete net5` → `qm start`. w1 then booted clean (5 NICs) + recovered.
>
> **MANDATORY corrected order (do NOT reboot a node with the NIC added until netplan knows about it):**
> - **Step 1 (netplan) MUST run BEFORE Step 1-old (TF NIC add).** Write the `enp6s23` `optional: true` stanza to ALL target nodes first (netplan accepts config for an absent interface). Only then add the NIC. With the stanza present, the reboot won't hang on wait-online.
> - **Drain properly:** `kubectl drain --ignore-daemonsets --delete-emptydir-data` BEFORE the reboot (the failed attempt rebooted without draining).
> - **Per node, verify Ready + sshd before the next.** If a node hangs >3 min, it's the wait-online trap — recover via the PVE kill/unlock/delete-net5 sequence above; don't wait indefinitely.
> - Consider whether the disruption/risk is worth it vs. the M36 suppression workaround — this is more involved than "additive + safe" implied.
>
> The TF + netplan changes were **reverted** after the incident (repo back to 5-NIC known-good). The exact diffs remain below for a corrected retry.



**Part of:** `docs/planning/metallb-bgp-migration-2026-05-29.md` (M18/M36).
**Goal:** give the NAS-workload nodes a direct L2 interface on VLAN 209 (the `vsan` SDN VNet) so kubelet NFS mounts to `sequoia` (10.10.209.10) stay on the switch fabric — *before* Servers/201 moves to UDM-routed in Phase B. ~~This phase is purely additive (no routing change) so it cannot disrupt anything.~~ **CORRECTION (see top banner): it is NOT free — the directly-connected 209 route changes the NFS *source IP*, which breaks mounts until the UNAS export ACL is told to permit the 209 IPs.** It also requires a reboot per node to enumerate the NIC.

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

## Expected first-boot noise (not an error)
When the new 209 NICs first DHCP, `switch-rackpoe` logs a short burst of
`DHCPS: Conflict detected(ping) ... pool dynamic 3 of intf vlan 209` /
`Lease Abandoned(conflict)` for `10.10.209.100–104` (and the `.10` static)
as the DHCP server probes addresses still ARP-cached from prior boots. Seen
once on 2026-06-03; silent since. Benign — the leases settle on the next
request. Only investigate if it **recurs** well beyond initial bring-up.
