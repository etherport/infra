# Terraform: UniFi (UDM Pro Max — site `wind`)

Manages UDM-side network config (VLANs, port forwards, static DHCP
reservations, eventually static routes + firewall) as code.

**Status:** Phase 1 skeleton only. No resources defined yet — runs of
`terraform plan` will succeed with "no changes" until the per-resource
files (`networks.tf`, `port-forwards.tf`, `reservations.tf`) are added.

## Why this module exists

- The UDM was hand-configured via the UI for years. The 2026-05-17 drift
  audit found a number of stale / undocumented resources (see
  `docs/planning/udm-config-drift-2026-05-17.md`).
- The `gh-runner` footgun (VM landed without a VLAN tag) wouldn't have
  happened if the L2 zone definitions and the VM provisioning shared a
  source of truth. UniFi-as-code closes that gap.
- Safety: today a UI typo can break inbound Twilio or WG access with no
  audit trail. With TF, every change goes through plan → review → apply.

## Operator prerequisites

| Prereq | Where it goes | Source |
|--------|---------------|--------|
| 1P SSH/age unlocked | Local session | Touch ID / passphrase |
| `terraform` binary | on `$PATH` | `brew install terraform` |
| AWS creds for S3 backend | env or profile | 1P "AWS — claude-admin IAM keys" |
| UniFi tf-admin user | UDM UI (already created) | 1P "Windroute (tf-admin)" — local-only admin |
| L3 reach to UDM API | VPN or LAN | homelab WG or on-site |

Quick verification before any plan:

```bash
ls ~/.config/sops/age/keys.txt          # exists
which terraform                          # exists, >= 1.5.0
op vault list >/dev/null                 # 1P session live
curl -sk -o /dev/null -w '%{http_code}' https://10.10.200.1   # 200/301/etc.
```

## Safety model

**Cardinal rule:** never `terraform apply` until `terraform plan` shows
`0 to add, 0 to change, 0 to destroy`. The whole point of Phase 1's
import-based bootstrap is to capture LIVE state as code without
mutating anything. If plan shows diffs, edit the HCL to match the live
UDM until plan is clean.

Before any apply, run the network safety check from the repo root:

```bash
./scripts/network/safety-check.sh > /tmp/safety-pre.log
# ... terraform apply ...
./scripts/network/safety-check.sh > /tmp/safety-post.log
diff /tmp/safety-pre.log /tmp/safety-post.log
```

Out-of-band recovery if something breaks:

1. **VPN paths:** K8s WireGuard (port 9821) and UDM WireGuard WAN1
   (port 60001) — independent paths into the homelab.
2. **Tailscale** — separate, non-UDM control plane.
3. **UDM config backup** — download via UI before any apply. Restore via
   UDM UI Settings → System → Backup & Restore.

Phase 1 **deliberately excludes** firewall policy + zone matrix imports
— those carry lockout risk and need their own phase.

## Apply paths

### Local (default for Phase 1 imports + verification)

```bash
cd infra/terraform/unifi
terraform init
export TF_VAR_unifi_username="$(op read 'op://Private/Windroute (tf-admin)/username')"
export TF_VAR_unifi_password="$(op read 'op://Private/Windroute (tf-admin)/password')"
terraform plan
```

If plan shows zero changes → import is correct, ready to commit. If
plan shows changes → edit HCL to match live state, re-plan, loop.

### GitHub Actions (post-Phase-1 ongoing management)

Workflow at `.github/workflows/terraform-unifi.yml` (not yet created;
mirror `terraform-proxmox-standalone-vms.yml`):
- Push to main touching `infra/terraform/unifi/**` → automatic `plan`
- Manual `workflow_dispatch` with `action: apply` → apply
- Runs on `[self-hosted, lifecycle]` (gh-runner has L3 reach to the UDM)

## Import procedure (Phase 1 bootstrap)

For each resource type:

1. Dump live state: `./scripts/unifi/dump-state.sh`
2. Read the JSON for the relevant resource (e.g. `networks.json`)
3. Author the `import {}` block + matching HCL resource definition
4. `terraform plan` — expect "no changes"
5. If diffs appear → edit HCL until clean
6. Commit HCL, move to next resource

Phase 1 order (lowest → highest risk):

1. VLANs / networks (`unifi_network`)
2. Static DHCP reservations (`unifi_user`) — only for infra hosts, not
   transient clients
3. Port forwards (`unifi_port_forward`)
4. Static routes (`unifi_static_route` — pending provider compatibility)

## Force-unlock procedure

Same S3 native-lock pattern as `proxmox/standalone-vms`. If an apply is
cancelled mid-flight and the next plan errors with `Error acquiring the
state lock`:

```bash
cd infra/terraform/unifi
terraform force-unlock <lock-id>     # from the error message
```

## Phase 2+ scope

- Firewall policies + zone matrix (high-risk, own phase)
- DDNS for `wan1.wind.etherport.net` integrated with Technitium (closes
  the stale-internal-DNS bug we hit on 2026-05-17)
- UniFi Protect + UNAS — if user wants those in code (currently UI-only)

See also: `docs/planning/udm-config-drift-2026-05-17.md` (the audit
this module is the response to).
