# Terraform: UniFi (UDM Pro Max — site `wind`)

Manages UDM-side network config (VLANs, static DHCP reservations, port
forwards, static routes) as code.

**Status:** live. `networks.tf`, `port-forwards.tf`, `reservations.tf`,
`routes.tf` all shipped + imported; `terraform plan` shows
`0 to add, 0 to change, 0 to destroy` against the live UDM (verified after
the M125 provider migration, 2026-07-02). If you see diffs, edit HCL to
match live state — don't apply blind.
Firewall zones + switch ACLs are NOT in this TF module — they're codified
via Ansible (`infra/ansible/playbooks/udm-firewall.yml` + `usw-acls.yml`).

## Provider: ubiquiti-community/unifi fork (M125)

The stack runs on **`ubiquiti-community/unifi` 0.41.25** — the maintained
community fork. The original `paultyng/unifi` provider is **archived/retired**;
the stack migrated off it on 2026-07-02 (M125) via a full schema rewrite +
state-rm/re-import session (details in `docs/planning/session-log.md`
2026-07-02 cont. 4b).

**Fork schema differences vs paultyng** (the fork is NOT drop-in — a plain
`terraform state replace-provider` corrupts plans; every resource needed
HCL changes):

- `unifi_network`: `vlan_id` → `vlan`; `purpose`/`network_group` removed;
  `internet_access_enabled` → `internet_access`;
  `intra_network_access_enabled` → `network_isolation` (**inverted**
  semantics); flat `dhcp_*` args → nested `dhcp_server = { ... }` attribute;
  `subnet` is **gateway-style** (`10.10.201.1/24`, not `.0/24`).
- `unifi_user` → **`unifi_client`** (same args). ⚠️ The fork **imports
  clients by MAC address**, not by controller `_id` — it rejects id-imports.
  A `moved {}` block can't express the type rename either; migration was
  done by `state rm` + re-import by MAC.
- `unifi_port_forward`: `fwd_ip`/`fwd_port` → nested `forward = { ip, port }`;
  `dst_port` → `wan = { port }`; `port_forward_interface` → `wan.interface`;
  `src_ip` → nested `source_limiting`; `enabled` deprecated (default on).
  The fork reads `wan.ip_address = "any"` from live records but rejects it
  as config — kept in `ignore_changes`.
- `unifi_static_route`: `distance` validates 1-255 (paultyng recorded the
  controller-default 0).
- Fork defaults diverge from live when unset — `auto_scale`, `lte_lan`,
  `setting_preference`, `gateway_type` are pinned explicitly per network.

**Fork fixes the paultyng PUT-400 bug.** paultyng deterministically 400'd
(`api.err.Invalid`) on network PUTs for clients/vsan/ceph (and mis-read
`dhcp_dns` on guest), which forced `dhcp_dns` into `ignore_changes` and
pushed the M110 DNS cutover through raw UDM API PUTs. The fork's PUTs are
all clean (47/47 during migration). The **whole-`dhcp_server`
`ignore_changes` entries remaining on clients / vsan / ceph / guest are
now removal candidates** — they also mask range/leasetime drift; drop them
one at a time and confirm plan stays clean (live UDM remains the source of
truth). NB the fork's occasional "Provider produced inconsistent result
after apply" errors are cosmetic read-back races, and the controller echoes
template DHCP values onto DHCP-disabled networks (see `inter_vlan_routing`).

**Auth / rate limit:** CI authenticates with the `tf-admin` local
username/password (GH secrets `UNIFI_USERNAME`/`UNIFI_PASSWORD`). For
local iterative sessions prefer a **`UNIFI_API_KEY`** (UDM UI → Control
Plane → Integrations) — repeated rapid username/password logins (~30 in the
M125 session) trip the UDM's **login rate-limiter** and lock the account
out temporarily; API-key auth doesn't.

## Why this module exists

- The UDM was hand-configured via the UI for years. The 2026-05-17 drift
  audit found a number of stale / undocumented resources (see
  `docs/planning/archive/udm-config-drift-2026-05-17.md`).
- The `gh-runner` footgun (VM landed without a VLAN tag) wouldn't have
  happened if the L2 zone definitions and the VM provisioning shared a
  source of truth. UniFi-as-code closes that gap.
- Safety: a UI typo can break inbound Twilio or WG access with no audit
  trail. With TF, every change goes through plan → review → apply.

## Safety model

**Cardinal rule:** never `terraform apply` until `terraform plan` shows
`0 to add, 0 to change, 0 to destroy` (plus, at most, exactly your intended
change). This stack is import-based: it captures LIVE state as code. If
plan shows unexpected diffs, edit the HCL to match the live UDM until plan
is clean — the live UDM is the source of truth.

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

Firewall policy + the zone matrix are **deliberately excluded** from TF —
they carry lockout risk and are codified via Ansible instead
(`udm-firewall.yml` + `usw-acls.yml`).

## Apply paths

### GitHub Actions (default — TF is CI-only, M82)

Workflow at `.github/workflows/terraform-unifi.yml`:
- Push to main touching `infra/terraform/unifi/**` → automatic `plan`
- Manual `workflow_dispatch` with `action: apply` → apply
- Runs on `[self-hosted, lifecycle]` (gh-runner has L3 reach to the UDM);
  creds from GH secrets (`UNIFI_USERNAME`/`UNIFI_PASSWORD`)

### Local (rare debug / state surgery — M82 throwaway-creds allowance)

```bash
cd infra/terraform/unifi
~/code/infra/scripts/render-aws-credentials.sh   # S3 backend creds (throwaway)
terraform init
export TF_VAR_unifi_username=...   # from the SOPS ops bundle or 1P "Windroute (tf-admin)"
export TF_VAR_unifi_password=...
terraform plan
```

For a longer local session, use a `UNIFI_API_KEY` instead of the login pair
(see the rate-limit note above).

## Adding / importing a resource

1. Dump live state: `./scripts/unifi/dump-state.sh`
2. Read the JSON for the relevant resource (e.g. `networks.json`)
3. Author the `import {}` block + matching HCL resource definition.
   Networks / routes / port-forwards import by controller `_id`;
   **`unifi_client` imports by MAC**.
4. `terraform plan` — expect "no changes"
5. If diffs appear → edit HCL until clean (pin the fork-default divergences:
   `auto_scale`, `lte_lan`, `setting_preference`, `gateway_type`)
6. Commit HCL

## Force-unlock procedure

Same S3 native-lock pattern as `proxmox/standalone-vms`. If an apply is
cancelled mid-flight and the next plan errors with `Error acquiring the
state lock`:

```bash
cd infra/terraform/unifi
terraform force-unlock <lock-id>     # from the error message
```

## Not in this module

- **Firewall policies + zone matrix** — Ansible
  (`udm-firewall.yml` + `usw-acls.yml`)
- **Per-network L3 router assignment** (e.g. the Ceph VLAN's US624P
  offload) — UI-only; neither the fork nor paultyng exposes it
- **UniFi Protect + UNAS** — UI-only today

## History

- **M125 fork migration (2026-07-02)** — paultyng → ubiquiti-community
  0.41.25; two earlier attempts (0.54, then 0.41.25 via replace-provider)
  proved the fork isn't drop-in and were cleanly reverted. Full narrative:
  `docs/planning/session-log.md` (2026-07-02 entries).
- **Phase 1 import bootstrap (2026-05-17)** + the drift audit that
  motivated it: `docs/planning/archive/udm-config-drift-2026-05-17.md`.
