> **Dated snapshot (2026-06-17).** Most gaps have since shipped: H37 (PVE firewall) ✅, H38 (Authentik internal SSO) ✅, M75 (IRSA) ✅, M76 (cert-only SSH) ✅, PSA now enforcing. Kept for the pillar-by-pillar reasoning; check `outstanding-work.md` for current status.

# Zero-Trust posture assessment — 2026-06-17

Requested by owner after M66 (Cilium WireGuard) landed: "evaluate what other
opportunities we have to implement a proper zero-trust structure — add the
Proxmox firewall (not yet discussed) and any other opps we haven't."

Zero-trust = *never trust, always verify · least privilege · micro-segment ·
encrypt everywhere · strong identity at every hop · assume breach · continuously
verify.* This maps the homelab against those pillars: what's **already done**, and
the **gaps** (now tracked as H37/H38, M72–M76, L24).

---

## Already in place (don't re-litigate)

| Pillar | Control | Where |
|--------|---------|-------|
| Micro-segment (network) | UDM zone-based firewall, custom zones intra-block-by-default; Trusted/Management split | M56, `firewall-zones.md` |
| Micro-segment (L3 fabric) | Switch ACLs on the L3-switch-routed VLANs (201/209/210) | M52, `usw-acls.yml` |
| Micro-segment (pods) | Cilium NetworkPolicies — **in progress** (H3, audit/observation, per-ns opt-in) | H3 |
| Encrypt east-west | **Cilium WireGuard pod-to-pod** (cilium_wg0, full mesh) | **M66 ✅ 2026-06-17** |
| Encrypt at rest (etcd) | `kube_encrypt_secret_data: true` — K8s secrets encrypted in etcd | kubespray inventory ✅ |
| Least privilege (CI→cloud) | GitHub→AWS **OIDC** (no static keys in CI); GCP **WIF** | H29 ✅ / L21 ✅ |
| Least privilege (RBAC) | Auto-remediation destructive verbs scoped to per-ns Roles | H32 ✅ |
| Identity at edge | Cloudflare Access (Google SSO) on public ingress | (edge only — see H38) |
| Secrets | SOPS+age, two recipients, CI decrypt-check, pre-commit gates | H33/L22 ✅ |
| Assume-breach (partial) | Pod Security Admission **audit/warn** labels + LimitRanges | `policy-baseline/` (Phase 1) |
| Continuously verify | Hubble flow visibility; Flux reconcile alerting; AI advisor | H3/H36 ✅ |

**Takeaway:** the *network* and *secrets/CI* pillars are fairly mature. The thin
spots are **identity for internal access**, the **hypervisor**, and the
**assume-breach** controls inside the cluster (admission + runtime).

---

## Gaps → new tracked items

### H37 — Proxmox host firewall (datacenter / node / VM), default-deny mgmt plane  *(owner-requested)*
The **hypervisor is the crown jewel** — own it and every VM/cluster falls — yet the
PVE firewall is **not managed in IaC and effectively permissive**. PVE has a built-in
nftables firewall at datacenter/node/VM scope; the `bgp/proxmox` provider already in
use exposes `proxmox_virtual_environment_firewall_*` resources (node firewall, VM
firewall, security groups, IPsets).
- **Do:** enable the firewall with **default-deny inbound**, then allow only: PVE API
  `8006` + SSH `22` **from the Management VLAN (200) / tailnet only**, VXLAN/cluster
  ports if/when a 2nd node joins, and the SDN/bridge needs. Per-VM firewall for the
  standalone VMs. Codify as Terraform (security groups + IPsets for the allowed source
  ranges). **Plan = 0-diff discipline; --check first.**
- **Risk:** lock-out — *always* keep an allow for the mgmt source before applying, and
  have console/IPMI access as the break-glass. **Tier: HIGH. Effort: M.**

### H38 — Internal identity-aware access (forward-auth at Traefik) — kill "internal = trusted"
**The biggest classic zero-trust hole.** CF Access is **edge-only**; any host on the
LAN hitting the Traefik VIP `10.10.201.70` reaches apps **with no auth** (CLAUDE.md
invariant). "On the internal network" currently == trusted, which is exactly what
zero-trust rejects.
- **Do:** put an identity gate in front of internal ingress too — a Traefik
  `forwardAuth` middleware backed by **Authelia / Authentik / oauth2-proxy** (Google
  SSO + per-service policy + optional MFA), or lean on **Tailscale-serve / tsnet** so
  app access requires tailnet identity. Apply to sensitive apps first (Grafana, HA,
  wiki, admin UIs).
- **Synergy:** also unblocks **L14** (public approval URL needs an auth gate).
  **Tier: HIGH. Effort: M–L.**

### M72 — Pod Security Admission: progress audit/warn → **enforce**
`policy-baseline/` runs PSA in **audit/warn only** (Phase 1, by design). A pod that
violates `baseline`/`restricted` is logged but **still admitted**. Assume-breach wants
**enforce**.
- **Do:** review the audit log (observation window has run since 2026-05), then flip
  `pod-security.kubernetes.io/enforce: baseline` (→ `restricted` where workloads allow)
  per namespace, leaving documented exceptions (`wireguard`, `blackbox` = privileged).
  Mirrors the H3 per-ns opt-in enforcement model. **Tier: MED. Effort: S–M.**

### M73 — Admission policy engine (Kyverno) — provenance + guardrails
No policy engine. Assume-breach + supply-chain wants cluster-side **admission
verification**: block unsigned images (cosign/sigstore — ties **H30**), disallow
floating `:latest` (ties **M64**; cue-api is the known intentional exception), require
resource requests/limits, drop `:privileged` without exception, enforce read-only
rootfs defaults.
- **Do:** deploy **Kyverno**, start in `audit` then `enforce`. Pairs with M72 (Kyverno
  can do richer rules than raw PSA). **Tier: MED. Effort: M.**

### M74 — Cilium Tetragon — eBPF runtime security / detection (assume-breach)
We have Cilium but no **runtime** detection — only network flow visibility (Hubble).
Tetragon (same vendor, eBPF) adds process-exec / file-access / privilege-escalation
detection → feed events to Loki/alertmanager + the AI advisor.
- **Do:** deploy Tetragon (Helm, like Cilium), start with default observability
  policies on tier-1 namespaces. **Tier: MED. Effort: M.**

### M75 — In-cluster workload identity for cloud access (kill long-lived IAM secrets)
In-cluster workloads (velero, etcd-backup, rclone, etc.) authenticate to AWS with
**long-lived static IAM keys in K8s Secrets** — the same class of standing credential
H29 removed from CI and M71 targets on the mini. Extend the OIDC pattern **into the
cluster**: stand up an IAM **OIDC provider for the cluster's service-account issuer**
(IRSA-style) so pods assume roles for **short-lived** creds, no static keys in etcd.
- **Do:** publish the K8s OIDC discovery doc, create the IAM OIDC provider + per-SA
  roles, migrate velero/etcd-backup/rclone off `existingSecret`. **Tier: MED. Effort: M–L.**

### M76 — SSH to nodes/VMs via short-lived certs (Tailscale SSH / SSH CA)
Node + VM SSH uses a **long-lived key** (`id_ed25519_homelab`). Zero-trust prefers
**short-lived, identity-bound** SSH — **Tailscale SSH** (natural: hosts are on the
tailnet; gate by tailnet ACL + check mode) or an SSH CA (step-ca) issuing minutes-long
certs. Removes the standing key as a single stealable secret. Pairs with **M71** (AWS
auth) under one "kill standing creds" theme. **Tier: MED. Effort: M.**

### L24 — Authenticate BGP sessions (MetalLB ↔ UDM)
The MetalLB↔UDM eBGP peers appear to run **without TCP-MD5/AO authentication**, so a
rogue host on the peering VLAN could attempt route injection. Low real-world risk on a
trusted fabric, but cheap defense-in-depth: set a BGP password on both ends.
**Tier: LOW. Effort: S.**

---

## Suggested sequence
1. **H37 Proxmox firewall** — highest blast-radius reduction; bounded, IaC-able now.
2. **H38 internal forward-auth** — closes the "internal = trusted" anti-pattern (+ unblocks L14).
3. **M72 PSA enforce** — cheap, observation window already elapsed.
4. **M73 Kyverno / M74 Tetragon** — deeper assume-breach (admission + runtime).
5. **M75 / M76** — finish the "no standing credentials" theme with M71.
6. **L24** — quick BGP-auth hardening whenever convenient.

Out of scope / already adequate for a single-owner homelab: full mTLS service mesh
(Cilium mutual-auth) beyond WireGuard+NetPol; CIS kube-bench gating; DNSSEC/DoT
internal. Revisit if the trust boundary widens (multi-tenant, exposed services).
