# Hardcoded ephemeral / drift-prone IP audit — 2026-05-23

Read-only sweep of `/Users/grahamsmith/code/infra` for IP literals that
will rot when the underlying address rotates (WAN/ISP, non-EIP cloud
public IPs, VPN/exit nodes, etc.). LAN ranges (`10.10.0.0/16`), cluster
service ranges (`10.43.0.0/16`), public DNS resolvers (`1.1.1.1`,
`8.8.8.8`, `8.8.4.4`), and AWS Elastic IPs that are managed in
Terraform are excluded.

## 1. Executive summary

| Class | Count | Notes |
|---|---|---|
| **DRIFT-DANGEROUS (act now)** | **1 occurrence in 2 files** | Mumbai regional-VPN endpoint `13.234.119.106` — non-EIP instance public IP referenced from IaC-active manifests. |
| **DRIFT-DANGEROUS (cosmetic / orphan)** | **1** | `var.ssh_allowed_ip` in `networking/variables.tf` is now unused (rules migrated to dns-restrict-ip Lambda on 2026-05-23) but the stale `47.159.189.230/32` default still ships. |
| **DOC DRIFT (stale claim, no functional impact)** | **2** | `outstanding-work.md` line 63 + `docs/architecture/aws-infrastructure.md` lines 88–112 still describe the old hardcoded SSH/DNS SG rules that were removed today. |
| **EIP-DUPLICATION DEBT (medium)** | **5 occurrences in 3 files** | `44.240.60.80` / `35.169.37.16` are EIPs (stable) but their literal values are copy-pasted into route53 var defaults + WireGuard playbook/manifest instead of being driven from the EIP resource or DNS. Drifts only if EIP allocation is destroyed and re-issued. |
| **REFERENCE-ONLY** | ~20 | Runbooks, MIGRATION_PLAN.md historical tables, doc examples, Twilio SIP carrier CIDRs, NordVPN setup-guide stub. No IaC impact. |
| **UNKNOWN / personal** | **2** | Tailscale CGNAT exit-node aliases in `scripts/dotfiles/.zshrc` (`100.117.87.10`, `100.117.63.43`) — Tailscale-assigned, technically may rotate if devices re-register. User-shell convenience only. |

The audit target list from the prompt also expected:
- `47.34.215.233/32` ("remote location") hardcoded in `security_groups.tf` — **already removed** today (commit on disk shows `removed{}` blocks for `ssh_restricted` + `ssh_remote`; SSH ingress is now Lambda-managed via `rule_specs`).
- `86.98.93.115/32` UAE residential IP — **never lived in Terraform**, only in a `dns-restrict-ip/variables.tf` comment as historical context. No drift exposure.
- NordVPN exit IPs (`146.70.238.*`) — **not present** anywhere in IaC. Only appears in the same `dns-restrict-ip/variables.tf` comment as a historical note about what the Lambda will reconcile away on its next run.
- Homelab WAN IPs (`66.215.210.75`, `47.159.189.5`) — only in `docs/planning/outstanding-work.md` (reference) and `aws-regional-vpn/main.tf` `homelab_endpoint` variable default (see §2.D below — currently REFERENCE-ONLY because the regional-vpn module is destroyed when no region is active, but it would be drift-dangerous when re-applied).

**Single most urgent item:** the Mumbai non-EIP. See §3.

## 2. Per-file findings

### A. DRIFT-DANGEROUS (live IaC)

| File:Line | IP | Context | Class | Suggested action |
|---|---|---|---|---|
| `/Users/grahamsmith/code/infra/infra/ansible/playbooks/wireguard.yml:92` | `13.234.119.106` | `endpoint: "13.234.119.106:51820"` — Mumbai (ap-south-1) regional VPN peer for the homelab wg0 NAS/router peer list. Pushed onto homelab on `ansible-playbook wireguard.yml` runs. | **DRIFT-DANGEROUS** | Replace with `vpn-mumbai.etherport.net:51820` (add DDNS via Route53 + the regional-vpn user-data script, OR pass through TF output during a deploy run), OR add `use_elastic_ip = true` to the `aws-regional-vpn` module so the value becomes stable. See §3. |
| `/Users/grahamsmith/code/infra/platform/kubernetes/wireguard/03-deployment.yaml:116` | `13.234.119.106` | `Endpoint = 13.234.119.106:51820` inside the K8s WireGuard pod's wg0 config (PostUp inline). Same Mumbai peer. Flux-reconciled. | **DRIFT-DANGEROUS** | Same fix as above. Both copies must stay in sync — having two literal duplicates makes this twice as fragile. |

### B. DRIFT-DANGEROUS (orphan / cosmetic)

| File:Line | IP | Context | Class | Suggested action |
|---|---|---|---|---|
| `/Users/grahamsmith/code/infra/infra/terraform/aws/networking/variables.tf:9-13` | `47.159.189.230/32` | `variable "ssh_allowed_ip" { default = "47.159.189.230/32" }` — no consumer left in the module (the rule that referenced it, `ssh_restricted`, is now a `removed{}` block in `security_groups.tf`; ingress is Lambda-managed). | **DRIFT-DANGEROUS-but-inert** | Delete the variable block entirely. Today it's harmless; if anyone re-introduces a `cidr_ipv4 = var.ssh_allowed_ip` rule, the stale default would silently lock out the wrong CIDR. |

### C. DOC DRIFT (claims rules exist that no longer do)

| File:Line | IP | Context | Class | Suggested action |
|---|---|---|---|---|
| `/Users/grahamsmith/code/infra/docs/planning/outstanding-work.md:63` | `47.34.215.233/32` | "**⏳ Still hardcoded:** `aws_security_group.allow_ssh` port 22 from `47.34.215.233/32`..." — actually unhardcoded as of today (2026-05-23). | REFERENCE-ONLY (stale) | Strike or move to "Done" — `dns-restrict-ip/variables.tf` now manages allow_ssh:22:tcp. |
| `/Users/grahamsmith/code/infra/docs/architecture/aws-infrastructure.md:88-89, 93, 112` | `47.159.189.230/32` (×3), `47.159.189.230` | DNS / SSH SG tables document `47.159.189.230/32` as if statically configured. Lambda has owned these for a while. | REFERENCE-ONLY (stale) | Replace literal with "dynamically set from wan1/wan2.wind.etherport.net by dns-restrict-ip Lambda". |

### D. EIP-DUPLICATION DEBT (stable today, fragile under rebuild)

These are EIPs in the underlying TF resource (`prevent_destroy = true`),
so they don't currently rotate. The risk is purely the
"hardcoded-default-of-an-EIP" anti-pattern: if the EIP ever IS destroyed
and reallocated, the literal in the dependent module/manifest goes
stale silently.

| File:Line | IP | Context | Class | Suggested action |
|---|---|---|---|---|
| `/Users/grahamsmith/code/infra/infra/terraform/aws/route53/variables.tf:21-25` | `44.240.60.80` | `variable "vpn_usw2_public_ip" { default = "44.240.60.80" }` — flows into `aws_route53_record.etherport_vpn_usw2`. The actual EIP lives in the `compute` module (`aws_eip.vpn`). | EIP-duplication-debt | Either (a) read the EIP via `terraform_remote_state` from the `compute` module and drop the default, or (b) leave the literal but add a `precondition` that asserts equality against a `data "aws_eip"` lookup. |
| `/Users/grahamsmith/code/infra/infra/terraform/aws/route53/variables.tf:27-31` | `35.169.37.16` | `variable "vpn_use1_public_ip"` — flows into `aws_route53_record.etherport_vpn_use1`. EIP lives in `aws-us-east-1/main.tf:629` (`aws_eip.vpn`). | EIP-duplication-debt | Same — pull from remote state. |
| `/Users/grahamsmith/code/infra/infra/terraform/aws-regional-vpn/main.tf:111` | `47.159.189.5` | `variable "homelab_endpoint" { default = "47.159.189.5" # Homelab public IP }`. This is the user's WAN2, which IS ISP-DHCP — but the module isn't currently applied (regional VPN destroyed when not traveling). When next applied, this default WILL be wrong if WAN2 rotated since last travel. | DRIFT-DANGEROUS-on-next-apply | Change default to `"wan2.wind.etherport.net"` (the value is passed to `aws_instance.vpn.user_data` → wg config Endpoint, which WireGuard re-resolves on handshake). Or split into `homelab_endpoint_hostname` / `homelab_endpoint_ip` and prefer the hostname. |
| `/Users/grahamsmith/code/infra/infra/ansible/playbooks/wireguard.yml:51` | `44.240.60.80` | `peer_endpoint: "44.240.60.80:51820"` for the `vpn_local` host's wg0 peer (the AWS vpn-aws EIP). | EIP-duplication-debt | Replace with `vpn-usw2.etherport.net:51820` (already an A record in route53 → same EIP). DNS is the source of truth; literal IP becomes self-healing. |
| `/Users/grahamsmith/code/infra/platform/kubernetes/wireguard/03-deployment.yaml:108` | `44.240.60.80` | `Endpoint = 44.240.60.80:51820` for vpn-aws wg0 peer (K8s pod config). | EIP-duplication-debt | Same — use `vpn-usw2.etherport.net:51820`. |
| `/Users/grahamsmith/code/infra/platform/kubernetes/wireguard/03-deployment.yaml:124` | `35.169.37.16` | `Endpoint = 35.169.37.16:51820` for vpn-use1 wg0 peer. | EIP-duplication-debt | Use `vpn-use1.etherport.net:51820` (already in route53). |

### E. UNKNOWN — needs human call

| File:Line | IP | Context | Note |
|---|---|---|---|
| `/Users/grahamsmith/code/infra/scripts/dotfiles/.zshrc:13` | `100.117.87.10` | `alias ts-aws='... --exit-node=100.117.87.10'` — Tailscale CGNAT IP of vpn-aws exit node. | Stable in practice if the Tailscale node is never re-registered. Switching to `--exit-node=vpn-aws` (Tailscale also resolves by node name) would be drift-immune. Personal dotfile, low priority. |
| `/Users/grahamsmith/code/infra/scripts/dotfiles/.zshrc:14` | `100.117.63.43` | `alias ts-home='... --exit-node=100.117.63.43'` — Tailscale CGNAT of homelab-router. | Same as above. Prefer `--exit-node=homelab-router`. |
| `/Users/grahamsmith/code/infra/infra/ansible/playbooks/tailscale.yml:197` | `100.75.199.69` | `K8S_ROUTER_IP="100.75.199.69"` — Tailscale CGNAT of K8s `homelab-router` pod, used by the vpn-local failover health-check script (pings this IP every 10s). | Tailscale CGNAT IPs are assigned on first registration and persistent; if the K8s router pod is ever re-created from scratch under a new Tailscale auth-key, this IP would change and failover would mis-fire silently. Either (a) resolve via MagicDNS hostname (`homelab-router.<tailnet>.ts.net`) inside the script, or (b) accept it and add a comment + log a Prometheus alert if the IP can't resolve. |

### F. REFERENCE-ONLY (documented, no IaC impact — skip unless touched)

Brief list, not exhaustive:

- `/Users/grahamsmith/code/infra/infra/terraform/aws/MIGRATION_PLAN.md:49-53` — historical EIP-by-name table.
- `/Users/grahamsmith/code/infra/docs/runbooks/aws-private-dns.md:14,33,34,64` — `52.40.219.113` (technitium EIP) in usage examples.
- `/Users/grahamsmith/code/infra/docs/runbooks/disaster-recovery.md:351,357` — `ssh ubuntu@44.240.60.80` example commands.
- `/Users/grahamsmith/code/infra/docs/runbooks/instance-migration.md:24,92,187` — same EIP for migration walkthroughs.
- `/Users/grahamsmith/code/infra/docs/runbooks/unifi-talk.md:52` — Twilio SIP edge CIDRs (`54.172.60.0/30`, etc.); these are Twilio-published carrier ranges and live in the UDM UI, not in IaC.
- `/Users/grahamsmith/code/infra/docs/architecture/vpn-wireguard.md:218,239` — `Endpoint = 44.240.60.80:51820` in example client configs.
- `/Users/grahamsmith/code/infra/docs/planning/outstanding-work.md:310` — sentence describing the existing `dns_server` SG behavior.
- `/Users/grahamsmith/code/infra/infra/terraform/aws/dns-restrict-ip/variables.tf:40-42` — comment listing historical stale IPs reconciled away by the Lambda.
- `/Users/grahamsmith/code/infra/infra/terraform/unifi/networks.tf:22,74,112,…` — `52.40.219.113` referenced in DHCP DNS lists, but this IS the live AWS technitium EIP and is genuinely used here (not drift-prone today; same EIP-duplication caveat as §D — could be replaced by a `var` populated from `aws/compute` outputs).
- `/Users/grahamsmith/code/infra/docs/guides/vpn-split-tunnel.md` — NordVPN setup guide (now archival; NordVPN was removed last week).

## 3. Recommended cleanup plan (priority order)

1. **Mumbai endpoint (DRIFT-DANGEROUS, live).** Pick one of:
   - **Option A (recommended, low effort):** Add `use_elastic_ip = true` to the `aws-regional-vpn` module (currently the module never allocates an EIP — only `infra/terraform/modules/regional-vpn` does, and `aws-regional-vpn/main.tf` is its own monolith without that toggle). Then add a Route53 A record `vpn-mumbai.etherport.net` driven by the EIP output. Update both `wireguard.yml:92` and `03-deployment.yaml:116` to use the FQDN.
   - **Option B (zero-cost):** Add the EIP allocation but keep the literal IPs out of code — have the regional-vpn TF apply produce a small artifact (e.g. updating a Route53 record + emitting a `mumbai_endpoint` output), and have the homelab WireGuard config templated from that output via a Flux/Kustomize patch or an Ansible task that pulls remote state.
   - Avoid: leaving the literals in. The Mumbai instance can be stopped/started any time (e.g. during cost-saving teardown / re-create) and silently break the homelab → Mumbai tunnel.

2. **`var.ssh_allowed_ip` orphan.** Delete `variable "ssh_allowed_ip"` from `infra/terraform/aws/networking/variables.tf`. Single-line change. No references remain.

3. **Doc drift.** Fix `outstanding-work.md:63` ("Still hardcoded") and `docs/architecture/aws-infrastructure.md:88-112` to reflect that allow_ssh + dns_server are both Lambda-managed.

4. **EIP-duplication debt — playbook + K8s manifest.** Easy win: replace the three `44.240.60.80` / `35.169.37.16` / `13.234.119.106` literal Endpoints in `ansible/playbooks/wireguard.yml` and `platform/kubernetes/wireguard/03-deployment.yaml` with the existing Route53 names (`vpn-usw2.etherport.net`, `vpn-use1.etherport.net`, plus the new `vpn-mumbai.etherport.net` from step 1). WireGuard re-resolves the endpoint on every handshake retry, so DNS-driven endpoints survive EIP reallocation transparently.

5. **EIP-duplication debt — route53 variable defaults.** `route53/variables.tf` `vpn_usw2_public_ip` / `vpn_use1_public_ip` defaults should be replaced by a `terraform_remote_state` lookup against `aws/compute` and `aws-us-east-1`. Today both modules already use S3 backends, so this is mechanical.

6. **`aws-regional-vpn/main.tf` `homelab_endpoint` default.** Change `default = "47.159.189.5"` to `default = "wan2.wind.etherport.net"`. WireGuard's `wg-quick` resolves Endpoint at start; on `systemctl restart wg-quick@wg0` (which happens periodically anyway) it'll re-resolve and pick up any WAN rotation.

7. **Optional: Tailscale CGNAT IPs.** Replace `100.x.x.x` literals in `ansible/playbooks/tailscale.yml:197` (and the user-shell aliases) with MagicDNS names. Not urgent — Tailscale IPs are stickier than EIPs in practice — but cheap and matches the "DNS is source of truth" pattern.

## 4. Open questions

- **Does `vpn-mumbai.etherport.net` already exist as a Route53 record?** A quick grep of `infra/terraform/aws/route53/` shows only `vpn-use1` and `vpn-usw2` records under the etherport zone. Confirm before doing step 1 above — may need to add the record to the regional zone or to the etherport zone.
- **Mumbai EIP cost-vs-benefit.** AWS charges for EIPs while attached (free) but per-hour while idle. If the Mumbai instance is destroyed between travel trips, an EIP held without an instance costs ~$3.60/mo. Acceptable for the operational simplicity, but worth flagging.
- **Anything still pointing at `52.40.219.113` outside Unifi networks.tf?** It's the AWS technitium EIP (stable). The Unifi DHCP-pushed DNS list literally embeds it as the tertiary resolver. Same EIP-duplication anti-pattern as §D — could be sourced from `aws/compute` outputs via remote state.
- **`scripts/setup-terminal.sh` and `docs/operations/terminal-setup.md`** still `brew install nordvpn` even though NordVPN was removed from the network last week. Not an IP audit finding, but flagging since it's adjacent — the brew install is harmless but stale.
