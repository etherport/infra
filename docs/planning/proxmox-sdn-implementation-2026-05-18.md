# Proxmox SDN Migration — Implementation Plan (2026-05-18)

## Reality check on the 2026-05-17 high-level plan

The high-level plan is directionally correct (VLAN zone, one VNet per VLAN), but contains three concrete inaccuracies that would cause `terraform plan` to fail if copied verbatim:

1. **Wrong resource names.** It asserts `proxmox_virtual_environment_sdn_zone_vlan`, `..._sdn_vnet`, `..._sdn_subnet`, `..._sdn_applier`. The provider exposes these resources under the **short alias** form `proxmox_sdn_zone_vlan`, `proxmox_sdn_vnet`, `proxmox_sdn_subnet`, `proxmox_sdn_applier` (added in v0.100.0, both forms registered; docs/examples use short form exclusively). The long form works too, but the official examples (and the changelog commit *"update /example/* to use short aliases"*) standardize on the short form. Recommend short form.
2. **VLAN list omits SimpliSafe-205.** Plan §4 lists VNets `servers, client, iot, security, vsan` — but the user has clarified VLAN 205 (Security/SimpliSafe) must NOT be retired; the K8s VMs have a NIC on 205 for Multus. The high-level plan happens to include `security` already, so this is fine — flag retained.
3. **`sdn_applier` is marked EXPERIMENTAL** in the upstream docs. Functional, but worth noting the stability label in the README so we don't fight the provider author over future schema churn. Mitigation: pin provider to `~> 0.106` (already pinned) and re-pin before bumping.

Provider compatibility confirmed against `~> 0.106` (changelog dated 2026-05-06). No version bump needed.

## Pre-work: provider + state surface verification

**Existing PVE SDN config (expected: none).** Run from a workstation with API token:

```bash
ssh root@pve.wind.etherport.net 'cat /etc/pve/sdn/zones.cfg /etc/pve/sdn/vnets.cfg 2>/dev/null; ls /etc/pve/sdn/'
# Expected: empty/no-such-file. If any zones exist, IMPORT (don't create) — see below.
```

**bpg/proxmox SDN resource names (verified 2026-05-18):**

| Resource | Required attrs | Notable optional |
|---|---|---|
| `proxmox_sdn_zone_vlan` | `id`, `bridge` | `nodes`, `mtu`, `dns`, `ipam` |
| `proxmox_sdn_vnet` | `id`, `zone` | `tag` (VLAN ID — REQUIRED for VLAN zone), `alias`, `vlan_aware`, `isolate_ports` |
| `proxmox_sdn_subnet` | `id`, `vnet`, `cidr` | `gateway`, `dhcp_range`, `dnszoneprefix` |
| `proxmox_sdn_applier` | none | `on_create` (default true), `on_destroy` (default true) |

`id` for VNets is **limited to 8 characters**, lowercase, alphanumeric. Plan with short names: `servers`, `clients`, `iot`, `security`, `vsan`, `mgmt`, `guest`, `unifi`. (VLAN 4040 / inter-VLAN routing transit is UDM↔L3-switch only — not modeled in PVE.)

**Import blocks (if PVE has pre-existing SDN — unlikely):**
```hcl
import { to = proxmox_sdn_zone_vlan.wind; id = "wind" }
```

## PR sequence

Branch each PR off `main`; merge before starting the next. All paths absolute below.

### PR 1 — TF module skeleton + CI workflow

**Files to create:**
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/backend.tf` — S3 backend, `key = "proxmox/sdn/terraform.tfstate"`, region `us-west-2`, bucket `terraform.wind.etherport.net`, `use_lockfile = true`, `profile = "homelab"` (mirrors standalone-vms/backend.tf line-for-line)
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/main.tf` — `required_version >= 1.4.0`, `bpg/proxmox ~> 0.106`, provider block identical to standalone-vms (endpoint `https://pve.wind.etherport.net:8006/api2/json`, `insecure = true`)
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/variables.tf` — `proxmox_token_id`, `proxmox_token_secret` (sensitive), `aws_profile` (default `homelab`). No `ssh_public_key` needed.
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/README.md` — mirror standalone-vms/README.md sections "Operator prerequisites", "Apply path: GitHub Actions", "Apply path: local Terraform"
- `/Users/grahamsmith/code/infra/.github/workflows/terraform-proxmox-sdn.yml` — copy of `terraform-proxmox-standalone-vms.yml` with `WORKING_DIR: infra/terraform/proxmox/sdn` and path filter `infra/terraform/proxmox/sdn/**`. Keep `runs-on: [self-hosted, lifecycle]` (gh-runner). Module touches zero VMs, so gh-runner-driven applies are safe.

**Effort:** 20 minutes. **Risk:** none (no resources defined yet — `terraform plan` shows zero changes).

**Rollback:** delete the directory + workflow file.

### PR 2 — Define SDN zone + VNets (zero VM impact)

**Files:**
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/zones.tf` — one `proxmox_sdn_zone_vlan` named `wind` with `bridge = "vmbr0"`, `nodes = ["pve"]`, `mtu = 1500`.
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/vnets.tf` — `locals.vnets` map keyed by short name with `tag` = VLAN ID; `for_each` over `proxmox_sdn_vnet`:

  | id | tag | purpose |
  |---|---|---|
  | `servers` | 201 | K8s + standalone VMs |
  | `clients` | 202 | K8s Multus NIC |
  | `iot` | 204 | K8s Multus NIC |
  | `security` | 205 | K8s Multus NIC + SimpliSafe (DO NOT retire) |
  | `vsan` | 209 | future use |
  | `mgmt` | 200 | PVE host VLAN |
  | `guest` | 206 | not used by VMs today |
  | `unifi` | 212 | UniFi controller traffic |

  VLAN 4040 (inter-VLAN routing transit between UDM and L3 switch) is intentionally NOT modeled — it's UI-only routing infrastructure that never carries VM traffic.

  Set `vlan_aware = false` on all. No `tag` for VLAN 1 (Default/199) — skip; nothing uses it for VMs.

- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/sdn/applier.tf` — one `proxmox_sdn_applier` named `finalizer` with `lifecycle.replace_triggered_by = [proxmox_sdn_zone_vlan.wind, proxmox_sdn_vnet.this]` and `depends_on` listing both. The applier re-runs whenever zones or vnets change.
- Skip `subnets.tf` for Phase 1 — UniFi runs DHCP, we don't want PVE-side dnsmasq competing. Subnets are useful for IPAM later if we adopt PVE-managed DHCP for sandboxes.

**Apply path:** gh-runner-driven (`gh workflow run terraform-proxmox-sdn.yml -f action=apply`). Zero VM impact. After apply, on PVE: `ls /sys/class/net/ | grep -E 'servers|clients|iot|security'` should show new bridge interfaces alongside `vmbr0`. VMs still use `vmbr0` + their existing `vlan_id`.

**Effort:** 1 hour (mostly waiting for plan/apply). **Risk:** very low. The VNets create new bridge devices on PVE; nothing depends on them yet.

**Rollback:** `terraform destroy` in the sdn/ module (the applier on_destroy=true cleans PVE). Or merge a revert PR.

### PR 3 — Canary VM migration (dns-fallback)

**Why dns-fallback first:** smallest blast radius, only consumer is gh-runner (which fails-over to technitium .5 in 10.10.201.5 — already configured in initialization.dns). Fixes are also reproducible if it breaks: re-clone from template takes 60s.

**NOT gh-runner first** — chicken-and-egg (gh-runner running its own NIC swap = self-kill, same class of bug as the 2026-05-16 watchdog incident).

**Edits to `/Users/grahamsmith/code/infra/infra/terraform/proxmox/standalone-vms/main.tf`:**

Change the `proxmox_virtual_environment_vm.standalone` resource's `network_device` block from:
```hcl
network_device { bridge = local.bridge_name; model = "virtio"; vlan_id = local.vlan_tag }
```
to:
```hcl
network_device { bridge = "servers"; model = "virtio" }
```

But only for `dns-fallback` — that requires splitting the resource (a `network_device` is per-resource, not per-`each.value`). Two options:

**Option A (recommended): per-VM bridge map in locals.** Add `bridge` field to each entry in `local.standalone_vms`:
```hcl
standalone_vms = {
  dns-fallback = { ..., bridge = "servers" }
  vpn-local    = { ..., bridge = local.bridge_name }   # still vmbr0
  gh-runner    = { ..., bridge = local.bridge_name }
}
```
Then the `network_device` block becomes `bridge = each.value.bridge`, with conditional `vlan_id` via `dynamic` block — or simpler, drop `vlan_id` entirely and accept that vpn-local + gh-runner stay on `vmbr0` *without* a tag temporarily (BREAKS THEM — bad).

**Option B (safer): two separate resource instances.** Split `dns-fallback` into its own resource (`proxmox_virtual_environment_vm.standalone_sdn`) and leave the others under `proxmox_virtual_environment_vm.standalone`. Requires `terraform state mv` to keep the existing VM.

Recommend **Option B** for PR 3 — surgical, no risk of breaking siblings. PRs 4–5 consolidate.

**Plan expectation:** in-place update of `network_device.0`. bpg/proxmox v0.106 hot-swaps a NIC without VM restart (TF perspective). PVE under the hood does `qm set 1001 -net0 ...`, which deletes/re-adds the tap device — ~5s of packet loss. **No VM reboot.**

**Apply path:** local Terraform (NOT gh-runner). The migration touches DNS infra; if it fails mid-way, gh-runner's outbound DNS could degrade. Run from the user's Mac on VPN.

```bash
cd /Users/grahamsmith/code/infra/infra/terraform/proxmox/standalone-vms
export TF_VAR_proxmox_token_id="$(op read 'op://Private/Proxmox VE Terraform Token/token id')"
export TF_VAR_proxmox_token_secret="$(op read 'op://Private/Proxmox VE Terraform Token/token secret')"
terraform plan -target='proxmox_virtual_environment_vm.standalone_sdn["dns-fallback"]'
terraform apply -target='...'
ssh -i /tmp/auto-key ubuntu@10.10.201.6 'ip -br a; ping -c2 10.10.201.1'
```

**Effort:** 45 minutes. **Risk:** low. If the network device hot-swap fails, the VM keeps the previous device live until PVE confirms the new one.

**Rollback:** revert the commit, `terraform apply -target=...` again. <5s back to `vmbr0` + `vlan_id=201`.

### PR 4 — Migrate vpn-local + gh-runner

**Order:** vpn-local first (local apply), then gh-runner (local apply only — gh-runner cannot migrate its own NIC).

**Edits:** consolidate Option B from PR 3 — move dns-fallback back into the main `proxmox_virtual_environment_vm.standalone` resource, edit `local.standalone_vms` to drop the per-VM `bridge` field, and change the shared `network_device` block to `bridge = "servers"` (no `vlan_id`). Then `terraform state mv` to merge state.

**gh-runner caveat:** must run from local Mac. The NIC hot-swap causes ~5s packet loss; if the runner is in the middle of a workflow, that workflow may flake. Schedule a quiet window.

**Effort:** 1 hour including `state mv`. **Risk:** low–medium for gh-runner (self-touch class).

**Rollback:** revert commit + local apply. Keep a copy of the pre-PR `local.standalone_vms` block in commit history.

### PR 5 — Migrate k8s-vms (drain → migrate → uncordon)

**Order (least to most critical):**
1. k8s-w4 (last worker, lowest workload weight)
2. k8s-w3, k8s-w2, k8s-w1 (one at a time)
3. k8s-gpu1 (GPU passthrough — verify ROM bar survives NIC swap)
4. k8s-cp3, k8s-cp2, k8s-cp1 (control planes last — etcd quorum tolerates one out)

**Edits to `/Users/grahamsmith/code/infra/infra/terraform/proxmox/k8s-vms/main.tf`:**

For each `network_device` block (4 per VM × 8 VMs = 32 blocks), change:
- `bridge = local.bridge_name` → `bridge = "servers"` (VLAN 201)
- `vlan_id = local.vlan_tag` → DELETE
- Block 2: `bridge = "clients"`, drop `vlan_id = 202`
- Block 3: `bridge = "iot"`, drop `vlan_id = 204`
- Block 4: `bridge = "security"`, drop `vlan_id = 205`

Per-VM workflow:
```bash
# 1. Cordon + drain
kubectl cordon k8s-w4
kubectl drain k8s-w4 --ignore-daemonsets --delete-emptydir-data --grace-period=120

# 2. Apply (gh-runner-driven OK for workers; LOCAL for control planes)
gh workflow run terraform-proxmox-k8s-vms.yml -f action=apply  # if scoped, otherwise local
# Or local-targeted:
cd /Users/grahamsmith/code/infra/infra/terraform/proxmox/k8s-vms
terraform apply -target='proxmox_virtual_environment_vm.workers["k8s-w4"]'

# 3. Verify Multus interfaces still functional
ssh ubuntu@10.10.201.56 'ip -br a; sudo netplan get | head -20'
kubectl uncordon k8s-w4

# 4. Wait for ready + run a Multus-using pod (e.g. home-assistant)
kubectl get pods -A -o wide | grep k8s-w4
```

Stage commits per-VM if desired; single PR is fine if reviewed carefully.

**Effort:** 4–6 hours wall-clock (drain timings dominate). **Risk:** medium per VM (Cilium tolerates a node bounce; etcd tolerates 1 of 3 CPs out, NOT 2). Sequencing-critical.

**Rollback per-VM:** revert that VM's network_device block, `terraform apply -target=...`.

### PR 6 — Cleanup

**Files:**
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/standalone-vms/main.tf` — delete `local.bridge_name`, `local.vlan_tag` (no longer referenced).
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/k8s-vms/main.tf` — same.
- `/Users/grahamsmith/code/infra/infra/terraform/proxmox/standalone-vms/README.md` — update IP/VLAN references to mention `bridge = "servers"` model.
- `/Users/grahamsmith/code/infra/docs/runbooks/vlan-interfaces-netplan.md` (if exists) — update to reference VNet names.

**Effort:** 30 minutes. **Risk:** none (dead code removal). `terraform plan` should show zero diff.

## Multus / Packer compatibility deep-dive

**Question:** does moving from `vmbr0` + `vlan_id=204` to `bridge = "iot"` (VLAN zone VNet) change what the guest sees?

**Answer: no.** Both paths deliver untagged 802.1Q frames to the guest's `enp6sN` interface. Mechanism:

- **Today:** PVE creates a tap device on `vmbr0` with `tag=204`. The bridge strips/adds the tag at the bridge port; guest sees untagged Ethernet on `enp6s20`.
- **After SDN:** PVE creates a VNet bridge `iot` that's itself a sub-interface of `vmbr0` with VLAN 204 baked in. The tap device sits on `iot` with no tag; guest sees the exact same untagged Ethernet on `enp6s20`.

The guest MAC is preserved (TF `network_device.mac_address` is computed and re-used on update — verified in v0.106). Netplan `51-vlan-interfaces.yaml` only sets `optional: true; dhcp: no` on `enp6s19/20/21` — purely link-up flags, no VLAN config. Multus NetworkAttachmentDefinitions reference `enp6s19/20/21` by name; they continue to attach.

**What user should test before PR 5:**
1. After PR 3 (dns-fallback on `servers` VNet), verify `ip link show enp6s18` (or whatever the dns-fallback NIC is) reports `state UP` with MAC matching prior. `arp -an` from another VM confirms reachability.
2. Spin up a one-off test VM (clone of 9001) attached to all 4 VNets, install netplan stanza, attach a Multus-style macvlan via `ip link add link enp6s20 ... type macvlan`, ping IoT gateway 10.10.204.1. Tear down after.

If `enp6sN` names shift (theoretical — they're stable on virtio-pci slot ordering; bpg orders network_device blocks by declaration), Multus will silently break. Mitigation: keep `network_device` block order identical pre/post migration. Order today: 201/202/204/205 → keep that order in the SDN'd version. Verified in main.tf — blocks are in the same vlan order across all k8s resources.

## Rollback procedure per PR

| PR | Undo |
|---|---|
| PR 1 | `git revert <sha>` — drops empty module + workflow. |
| PR 2 | `terraform destroy` in sdn/ module (applier cleans PVE). Or revert + re-apply. |
| PR 3 | Revert commit, local `terraform apply -target=...["dns-fallback"]`. ~5s. |
| PR 4 | Revert commit, local `terraform apply -target=...` per VM. |
| PR 5 | Revert per-VM blocks; `terraform apply -target=...workers["k8s-wN"]`. Drain again first. |
| PR 6 | Revert commit. Cosmetic only. |

**Catastrophic rollback:** `ssh root@pve.wind.etherport.net 'rm /etc/pve/sdn/*.cfg && pvesh set /cluster/sdn'`. Then in TF, `terraform state rm proxmox_sdn_*`. VMs still bound to "servers" bridge will fail next reboot — but PVE keeps the bridge interface live until reboot, so there's a recovery window.

## Estimated time

| PR | Focused effort | Calendar | Apply path |
|---|---|---|---|
| 1 | 20m | same day | gh-runner |
| 2 | 1h | same day | gh-runner |
| 3 | 45m | next day (validate dns-fallback overnight) | local |
| 4 | 1h | next day | local (gh-runner step) |
| 5 | 4–6h | 1–2 days (drain windows) | mixed, CPs local |
| 6 | 30m | same day as PR 5 | gh-runner |
| **Total** | **~8h focused** | **~1 week calendar** | |

## Open questions to confirm before PR 1

1. **VNet `mgmt` (VLAN 200):** include? PVE host itself is on 200 — defining a VNet bound to 200 is harmless (no VM uses it) but could confuse a future operator. Recommend YES, include for completeness.
>GS: yes, include
2. **VLAN 4040 (intervl):** included as `intervl` VNet. Confirm no VM should be migrated onto it (it's an L3 transit, not a workload network).
>GS: is this a UI only network for internal routing? i don't think we'll need it in PVE but confirm
3. **Provider version pin:** stay at `~> 0.106` or bump to `~> 0.106.0` (strict patch)? Recommend keep `~> 0.106`.
>GS: go with recommended
4. **gh-runner-driven apply for PR 2:** confirmed safe (no VM mutation), but the sdn/ module's CI workflow inherits the same gh-runner pool. Acceptable.
>GS: what is best long term option here? let's aim to get everything in a state in which we would have if we used SDN from day 1
5. **DHCP/IPAM:** skip in Phase 1 (UniFi is authoritative). Re-evaluate if/when adding a sandbox VLAN.
>GS: fine for now
