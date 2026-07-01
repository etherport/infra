# AWS VPN + DNS consolidation → one t4g.small (plan)

**Status:** 🟡 **IN PROGRESS — partially executed 2026-07-01** (tracker M110 / task #43; plan dated 2026-07-01).
**Current state = the session-log 2026-07-01 entries** ("M110 executed (partial)" + its UPDATE):
us-east-1 spoke decommissioned (Phase 6 ✅), `vpn-aws` resized t4g.small + renamed
`private-infra_edge` ✅, cert-SSH bootstrap applied on the edge box ✅. **Still pending:** Technitium
fold, DNS cutover, dns-box destroy + EIP `52.40.219.113` release, SG redesign (Phase 1 F1–F7),
monitoring cleanup (Phase 5) + travel-tooling cleanup.
⚠️ **Correction to "Why (1)" below:** the flap turned out to be intermittent homelab↔AWS **path**
packet loss (WAN/ISP, in waves), **NOT the t4g.nano ENA allowance** — the resize is still justified
(RAM for the multi-service box) but is not the flap fix. See session-log 2026-07-01 UPDATE.

## Goal
Collapse the two us-west-2 t4g.nano instances — `vpn-aws` (WireGuard hub, `.10`, EIP `44.240.60.80`)
and `dns-aws` (Technitium DNS replica, `.5`, own EIP) — onto **one t4g.small**, and decommission the
**us-east-1** standing VPN + the **travel-VPN** tooling.

**Why:** (1) the flapping is the t4g.nano **ENA pps-allowance** (idle CPU, deterministic policing) — a
`t4g.small` has a larger allowance and fixes it; (2) drops one EIP + one instance + one EBS
(~$88/yr) — net **cheaper than today even after the resize**; (3) simplifies (one box, one identity).
Cost: current ≈ $22/mo → target ≈ $10–13/mo.

## Architecture (target)
**Resize the existing `vpn-aws` instance to t4g.small and fold the DNS role onto it** (don't build a
new box — keeping the vpn instance preserves the WG endpoint EIP + all keys = zero client churn):
- One `t4g.small`, primary private IP **`10.10.100.10`** + secondary **`10.10.100.5`** on one ENI,
  `source_dest_check=false`, retained EIP **`44.240.60.80`**.
- Runs: **wg0** (homelab site-to-site, listens :51820), **wg1** (remote-access, :51821), **tailscaled**
  (advertises `10.10.100.0/22`, exit node), **Technitium** (binds `0.0.0.0:53`, answers on `.5`),
  node_exporter (+ `--collector.ethtool` to watch ENA allowance).
- Both roles keep their existing identities: wg0 pubkey `kHjcUM…`, shared wg1 keypair `Aav0cNl4…`,
  Technitium on `.5`. **Nothing on any WG client or `dns-sync` changes.**

## Decision: keep the VPN EIP `44.240.60.80` — ✅ CONFIRMED (2026-07-01)
Operator confirmed: keep `44.240.60.80` (also easier to remember), release the dns EIP `52.40.219.113`.
DNS now answers on `44.240.60.80`. The released dns-EIP's consumers (below) get re-pointed.

### Where the dns public IP `52.40.219.113` is referenced (audited — only 1 live-config place)
- **`infra/terraform/unifi/networks.tf`** — `dhcp_dns = ["10.10.201.5","10.10.201.6","52.40.219.113"]`
  on **7 VLANs** (management L74, servers L112, clients L150, iot L188, vsan L311, unifi L349, ceph L400).
  Matches the live UDM (polled). **Post-cutover: change `52.40.219.113` → `44.240.60.80` on all 7**, apply
  via the unifi TF (CI), then **verify by polling `udm networkconf`** (the `paultyng/unifi` provider is
  write-only for `dhcp_dns` — it writes but doesn't read-back for drift, so a config change still applies;
  fall back to a UDM API POST if the write is a no-op). Guest VLAN (public DNS by design) is untouched.
- **`dns-restrict-ip` Lambda** (`aws/dns-restrict-ip/variables.tf` `rule_specs`) manages port-53 ingress on
  `sg-08d12e417159c18d2` (the dns SG) from the homelab WAN IPs → **re-point `rule_specs` to the consolidated
  SG** so failover DNS queries to `44.240.60.80:53` are still WAN-allowed.
- Docs only: `docs/architecture/aws-infrastructure.md` (instance table), `outstanding-work.md` (M104 note) — update.
- **Not elsewhere** — no device/service in the repo hardcodes it beyond the above (grep-confirmed).

### (original recommendation, retained for context)
The mapping showed keeping the dns EIP would be the higher-churn path:
- **Keep VPN EIP `44.240.60.80` (recommended):** it's baked into every WG client (k8s pod, vpn-local,
  device `.conf` profiles, `vpn-usw2.etherport.net`) → **zero client change**. The DNS role's public
  side has **no published record** (the dns EIP isn't in any CF/Route53 record — only a private A
  `dns-aws→10.10.100.5`), so re-pointing DNS failover ingress to `44.240.60.80` is fully IaC-contained
  (the `dns-restrict-ip` Lambda SG target + CloudFront origin + wherever devices get the resolver IP).
- **Keep DNS EIP (your proposal):** requires re-pointing **all** WG clients — including the `.conf`
  profiles on your phone/laptop (manual, per device) + `vpn-usw2` + the k8s pod + vpn-local. More work,
  more risk, no benefit (the dns EIP has no dependents to preserve).

**Recommendation: keep `44.240.60.80` (the vpn EIP), release the dns EIP.** Your intent ("one public
IP serving both roles, vpn DNS name on it") is met — the retained IP just happens to be the vpn one.
*(If you have a device hardcoded to the dns EIP as a resolver, tell me and we reconsider.)*

## Pre-flight (resolve before apply)
1. **Read the retained EIP + confirm stack ownership** — `terraform output` on `aws/compute` for the
   EIP values; confirm the vpn instance is owned by `aws/compute` (not `aws-regional-vpn`).
2. **Mint a Tailscale auth key** (admin console, tag `tag:subnet-router`, reusable/ephemeral+preauth) —
   the auth key is NOT in SOPS; passed at runtime. Confirm whether tailscaled is already live on the box.
3. **Verify two SG-audit unknowns** (need AWS-host confirmation): is **wstunnel** (tcp/443 world, `F4`)
   actually running? is **DoH/CloudFront** (`F5`) actually served? Drop the rule if not.
4. **Confirm no active us-east-1 / travel session** before destroy.

## Phase 0 — Security hardening / management parity (the box is public-facing)
Audit of what the box gets today vs the fleet baseline:
- **Already in line (base.yml, it's in `[all]`):** OS **auto-updates** (`unattended-upgrades` +
  `automatic_reboot=true` + staggered windows — **so yes, auto-updates are already on**), sshd hardened
  (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`), NTP (chrony), node_exporter,
  CloudWatch agent + role, encrypted EBS, IMDSv2-required.
- **Gaps to close (fold into consolidation):**
  1. **Cert-only SSH (M76 parity)** — the AWS boxes are the ONLY fleet hosts not on cert-only SSH: they
     reject the step-ca cert and still carry the static `automation@homelab` bootstrap key. → run
     `step-ca-trust.yml` + `step-ca-hostcerts.yml` against `inventory/aws` (user-CA trust needs no runtime
     step-ca dependency — just the CA pubkey in `TrustedUserCAKeys`), verify the devbox/CI cert authenticates,
     then `step-ca-remove-static-key.yml` to strip the static key.
  2. **SSH off the public IP → Tailscale-only** — we're installing tailscaled anyway; drop the public SSH
     SG rule (Phase 1) and reach SSH over the TS IP. Eliminates public SSH exposure entirely.
  3. **SSM Session Manager break-glass** — an EC2 has no PVE-console/IPMI equivalent; add SSM to the instance
     role (`AmazonSSMManagedInstanceCore`) so "cert + Tailscale both down" is still recoverable.
  4. **Technitium recursion ACL** — confirm recursion is restricted to the tunnel/homelab networks (never an
     open resolver), as defense-in-depth behind the SG-scoped `:53`.
  5. **Staggered `reboot_times` entry** for the consolidated box (base.yml) — an auto-reboot now blips BOTH
     DNS + the VPN gateway; pin it off-peak (the `.5`/`.6` resolvers + WG auto-re-handshake cover the window).
- **Optional (not fleet parity today):** fail2ban (SSH already SG-restricted + key-only → low value once
  SSH is Tailscale-only), auditd.

## Phase 1 — Security-group audit + least-priv redesign (`aws/networking`)
Findings (fix during consolidation):
- **F1 (delete):** `internal_aws_spokes` = `-1` from `10.10.96.0/19` — covers *only* the decommissioned
  use1 (`10.10.104.0/22`) + travel VPCs. Dead after Phase 6. Delete the rule + the `aws_route.hub_to_use1`.
- **F2/F3 (scope):** `internal_vpc` / `internal_s2s_vpn` / `internal_vpn_clients` grant blanket `-1`.
  Replace with port-scoped rules — critically, `:5380` (Technitium admin) must be reachable from the
  **homelab CIDR only**, NOT from `10.254.0.0/24` remote clients.
- **F4/F5 (verify-then-drop):** `vpn_wstunnel` 443/world + `dns_https_cloudfront` 443 — keep only if
  those services are confirmed running.
- **F6 (manual):** revoke stale `/24` remnants the `dns-restrict-ip` Lambda can't manage.
- **F7:** verify + delete orphaned `alb-public-443` SG if unused.
- **Correct as-is:** no Tailscale inbound rule (TS is outbound/DERP — none needed).

**New `consolidated-vpn-dns_sg`** (replaces the 4-SG pile-up on this box):
| Proto | Port | Source | Note |
|---|---|---|---|
| udp | 51820 | homelab WANs (`47.159.189.5/32`,`66.215.210.75/32`) | wg0 — **Lambda-managed** (add a `rule_specs` entry so WAN-IP changes self-heal); no longer `0.0.0.0/0` |
| udp | 51821 | `0.0.0.0/0` | wg1 clients dial in from anywhere |
| tcp+udp | 53 | homelab WANs (Lambda) + `10.10.192.0/19` | DNS failover; **NOT** world (open-resolver) |
| tcp | 5380 | `10.10.192.0/19` only | Technitium admin — homelab over tunnel only |
| tcp | 9100 | `10.10.192.0/19` | node_exporter (arrives masqueraded as homelab CIDR) |
| tcp | 22 | homelab WANs (Lambda) | SSH |
| icmp | all | tunnel CIDRs | diagnostics |
| egress | all | `0.0.0.0/0` + `::/0` | forwarder/NAT |

Point the `dns-restrict-ip` Lambda `rule_specs` at the new SG (+ add the `:51820 udp` spec).

## Phase 2 — Terraform (compute + networking)
**`aws/compute/main.tf`:** resize `aws_instance.vpn` → `t4g.small`; add secondary private IP
`10.10.100.5` (explicit `aws_network_interface` with `private_ips=[.10,.5]`, `source_dest_check=false`,
SGs `[consolidated, allow_ssh]` — the explicit ENI gives a **stable id** for the route table); keep
`source_dest_check=false`; re-associate the **retained EIP** to the box. Lift `prevent_destroy` on the
`dns` instance + dns EIP → **destroy them**. Clean `import.sh` dead lines.
**`aws/networking/route_tables.tf`:** point `local.vpn_network_interface_id` at the new ENI id (fixes
the 3 homelab/client/S2S routes at once). No other networking change (SG IDs are var-defaults, not remote-state).
Apply order: **networking plan first** (SG changes), then **compute** (instance). Both via CI OIDC dispatch.

## Phase 3 — Ansible re-provision (idempotent; ship via `ansible-vm-fleet.yml`)
Inventory `aws/inventory.ini`: keep the one host `vpn-aws` in **`[vpn_servers]` + `[dns_servers]` +
`[tailscale_nodes]`**. Run (limit=vpn-aws): `base` → `swap`(optional, 2GB now) → `wireguard` (wg0+wg1,
unchanged keys) → `technitium` (folds DNS on; retarget its host to this box, still binds `.5`) →
`tailscale` (`-e tailscale_auth_key=…`). Add `--collector.ethtool` to node_exporter in `base.yml`.

## Phase 4 — Cutover (DNS answering throughout)
The resize is an in-place stop/start (~1–2 min); the EIP + keys persist. Sequence to avoid a DNS gap:
1. Fold DNS onto the box **before** touching the old dns instance (add `.5` secondary IP + run
   technitium there) → verify `dig @10.10.100.5` answers from the new box.
2. Only then destroy the standalone `dns` instance. During the brief window both `.5`s can't coexist —
   so do the TF apply that *moves* `.5` to the new ENI as the cutover step (AWS moves the secondary IP
   atomically), then re-run technitium. The `.6` VM fallback + `.5` k8s VIP cover any blip (dns-aws is tertiary).
3. Verify wg0 re-handshakes (homelab dials `44.240.60.80`, PersistentKeepalive 25s), wg1 client connects,
   tailscale node shows `10.10.100.0/22` advertised + approved, Technitium answers on `.5`, dns-sync green.

## Phase 5 — Monitoring / CloudWatch / status
- **Scrape (`01-external-scrape-config.yaml`):** delete the `10.10.100.10:9100` target + its relabel
  (one node_exporter, one IP → keep `.5`/`dns-aws`); avoids double-scrape.
- **Alerts (`02-external-alerts.yaml`):** exprs are label-based (no change); update the stale
  `vpn-aws` comments.
- **CloudWatch (`compute/monitoring.tf`):** remove the 3 `vpn_*` alarms (mem/swap/status-recover);
  keep the 3 `dns_*` (they follow the survivor); refresh the stale "t4g.nano 0.5GB" swap comments.
- **service-status (`services.py`):** delete the `vpn-aws` row; fix the "2 AWS" comment.
- **Dashboard (`service-status.yaml`):** delete the `vpn-aws` panel; remove `vpn-aws.*` from the 3
  aggregate exprs; **total `45 → 44`**.
- Consider a new **`AWSReplicaHostEnaThrottle`** alert on `node_ethtool_..._allowance_exceeded` once the
  collector is on (proves/monitors the fix).

## Phase 6 — Decommission us-east-1 + travel (per the earlier scoping)
- **us-east-1 (`vpn-use1`):** remove the wg0 peer from `platform/kubernetes/wireguard/03-deployment.yaml`;
  destroy `infra/terraform/aws-us-east-1/` (⚠️ its CI workflow has **no destroy action** — add one or
  destroy locally via M82 throwaway creds); delete the `vpn-use1` CF record, `vpn-use1.sops.yaml`, the
  CI workflow, the drift-matrix entry, the S3 tfstate.
- **Travel tooling:** $0 standing (already torn down) → code/doc cleanup only: delete
  `aws-regional-vpn/` + `modules/regional-vpn/` + its workflow + `regional-peers.yaml` + the
  `wg0_regional_peers` block + `vpn-travel` CF record + the disabled `Wireguard Travel 9820` UDM
  forward (keep `Wireguard Local 9821`) + the regional-vpn runbook. (Skip entirely if you want to keep
  the trip capability — it costs nothing idle.)

## Phase 7 — Docs + tracker
Update `docs/architecture/vpn-wireguard.md`, `platform/wireguard/README.md`, the `policy.hujson`
comment, `CLAUDE.md` (if it mentions the 2-box AWS setup), the tracker (M110/#43) + session-log. Check
`.gitleaks.toml` path-allowlist before moving/deleting any allowlisted doc.

## Rollback
Each phase is reversible: TF `prevent_destroy` guards the instances (destroy is deliberate); the resize
is stop/start (revert instance_type); the SG changes are additive-then-subtractive (keep the old SGs
attached until the new one is verified); Ansible is idempotent; the EIP stays put. Worst case, the `.6`
VM + `.5` k8s VIP keep DNS up throughout (dns-aws is tertiary), and the homelab re-dials the WG endpoint
automatically. Keep the `dns` instance destroy as the LAST compute step so it's trivially un-done (re-add
the block) before that point.
