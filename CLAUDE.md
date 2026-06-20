# CLAUDE.md — agent entry point for `homelab-infra`

You are working in the **`wind` homelab infrastructure monorepo** (`sparked-diamond/infra`).
Single source of truth for a Proxmox + Kubernetes (Flux GitOps) + AWS + UniFi +
Cloudflare homelab. **If it's not in git, it doesn't survive a rebuild.**

This file gets you oriented fast. It does **not** duplicate the README — read that
for the full picture. It captures the operating model, the non-obvious gotchas,
and the rules for keeping the project's durable memory current.

---

## 1. Read these first (in order)

1. **`README.md`** (repo root) — project overview, architecture diagram, "How to
   apply changes", documentation map. The canonical reference.
2. **`docs/planning/outstanding-work.md`** — the **live to-do tracker**. Items keep
   stable IDs (`H29`, `M53`, `L21`…) across revisions so history is grep-able.
   Status legend: ✅ done · 🟡 in progress · ⏳ pending · 📋 drafted/awaiting apply.
3. **`docs/planning/session-log.md`** — **narrative journal** of what each working
   session did, why, and how to resume. Read the latest entries to know where we
   left off. This is the "pick up after a chat-history loss" artifact.
4. **`docs/README.md`** — index into `docs/{architecture,runbooks,operations,reference,setup,guides,planning}`.
5. User's Claude Code memory lives outside the repo at
   `~/.claude/projects/-Users-grahamsmith-code-infra/memory/` (`MEMORY.md` + files).
   It holds operator preferences + cross-session facts. Repo `CLAUDE.md` is the
   in-repo equivalent that any agent (any tool, any machine) can read.

## 2. Repo map

```
clusters/wind/        Flux entrypoint — GitRepository/Kustomization, helm-releases/, image-automation/
platform/kubernetes/  Per-namespace manifests + helm values (Flux-managed)
infra/terraform/      TF stacks: proxmox/ aws/ unifi/ cloudflare/ aws-regional-vpn/ google/ aws/github-oidc/
infra/ansible/        Playbooks: Proxmox host, standalone VMs, UDM (udm-firewall.yml, technitium.yml, …)
infra/kubespray/      Kubespray submodule + wind inventory
docs/                 architecture/ runbooks/ operations/ reference/ setup/ guides/ planning/
scripts/              helpers (network/safety-check.sh, render-aws-credentials.sh, unifi/, …)
```

## 3. Operating model (how change actually ships)

- **GitOps, branch = `main`.** Flux watches `main` → `clusters/wind`. Editing a
  manifest does nothing until committed + pushed + reconciled. The headless agent
  hosts auto-push to `main` (no branch protection — single-owner repo, accepted risk
  L20). **As of 2026-06-18 the Claude Code dev sessions run on the `devbox`** (not the
  mini — M81); the mini is kept for macOS-only iCloud work. Renovate also auto-merges
  to `main`, so a push can be rejected → `git pull --rebase origin main` then re-push.
- **Validate before commit:** `kubectl kustomize <dir>` (there is **no standalone
  `kustomize` binary** — use `kubectl kustomize`). For new CRDs, `kubectl apply
  --dry-run=server -f` validates against live CRDs.
- **No `flux` CLI on the mini.** Trigger reconciles via annotation:
  ```bash
  kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
  kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
  kubectl annotate --overwrite -n flux-system helmrelease/<name>     reconcile.fluxcd.io/requestedAt="$(date +%s)"
  ```
  Watch `.status.lastAppliedRevision` / `.status.artifact.revision` to confirm.
- **Terraform** ships via GitHub Actions workflow_dispatch (CI uses GitHub→AWS
  **OIDC**, not static keys — H29; GCP uses **WIF** — L21). See README "How to apply".
- **UDM/UniFi changes:** the `paultyng/unifi` TF provider covers networks/reservations/
  port-forwards; zone-based firewall + DNS live in **`infra/ansible/playbooks/udm-firewall.yml`**
  (drives the internal `/proxy/network/v2/api/...`). **Always `--check --diff` first**
  and only apply if the diff is exactly your change (the playbook full-reconciles).
- **Safety rules:** never `terraform apply` unless plan is reviewed/zero-diff;
  the UniFi TF README's cardinal rule is plan = `0 to add/change/destroy` before apply.

## 4. Secrets & access (this matters — read before touching secrets)

- **SOPS + age.** Primary age private key at `~/.config/sops/age/keys.txt` on **both
  the mini and the devbox** (devbox copy deployed by `devbox.yml` so dev-session agents
  can `sops -d` headlessly — confirmed working). NB: this makes devbox disk a **4th
  holder** of the primary key (was 3 per H33: mini disk, GH `SOPS_AGE_KEY`, Flux
  `sops-age`) — factor into blast-radius/rotation. The agent-readable bundle is
  **`infra/ansible/playbooks/secrets/homelab-ops.sops.yaml`** (`sops -d` it for
  aws/udm/cloudflare/etc. creds headlessly). Other `*.sops.yaml` files are scattered
  per-component. A pre-commit gate blocks plaintext secrets.
- **`op` (1Password CLI) does NOT work from agent bash** — it only authorizes the
  user's interactive/VNC terminal. To get a 1P secret the bundle lacks: ask the user
  to dump it to a file in their VNC terminal (mini-local) and read it there, or have
  them add it to the SOPS bundle. Don't burn cycles retrying `op` from your shell.
- **devbox** (`10.10.201.45`, tailnet `100.74.216.102`, Ubuntu, user `ubuntu`) =
  always-on Linux host where the **Claude Code dev sessions live** (M81, since
  2026-06-18). No FileVault gate → sessions auto-resume on reboot (systemd user unit
  `claude-sessions.service` + `loginctl enable-linger`; per-repo tmux running
  `claude --continue`, see `infra/devbox/`). **Has:** `kubectl` (cluster-admin),
  `sops`+age, `git`, `claude`, **and (since 2026-06-19) `terraform` 1.15.5 + `aws` CLI** —
  TF runs headlessly here: `scripts/render-aws-credentials.sh` writes the `~/.aws`
  `[homelab]` profile from SOPS (S3 backend) + `scripts/tf-proxmox.sh <stack> <args>`
  injects the PVE token. ⚠️ **This put the homelab AWS profile + PVE token on devbox — a ZT
  blast-radius expansion from the original "no TF/creds" design; accepted for now, revisit
  (re-home to mini/CI or keep).** **Still lacks:** a browser (headless-Chrome verification →
  mini/CI) and `gh` CLI (can't dispatch GH Actions from here). Auth: Claude OAuth is broken
  on headless Linux (GitHub #47152) → token transplanted from the mini's Keychain into
  `~/.claude/.credentials.json`. Provisioning: `infra/ansible/playbooks/devbox.yml`
  (+ `infra/devbox/README.md`).
- **Mac mini** (`10.10.202.101`, tailnet `100.79.165.113`) = always-on headless
  ops/RC host: full kubectl/terraform/sops/ansible, **no 1P at runtime**. Retained for
  macOS-only iCloud backups (M79/M80) + as the TF/AWS-capable ops box. Procedure:
  `docs/setup/headless-ops-host.md`.
- **Appliances:** UDM Pro `10.10.200.1` (Network v2 API via `udm_api_key` `X-API-KEY`,
  or `udm_tfadmin_*` login). UniFi Protect = **`Windprotect` `10.10.212.10`** (SSH via
  `udm_ssh_user`/`udm_ssh_password`; integration API via `protect-tf` key but it's
  **read-only — Alarm Manager automations are UI-only**). UNAS `10.10.209.10`.
- **Never delete the `terraform-homelab` IAM access key** — it's shared with the local
  homelab profile (H29 cutover note).

## 5. Key invariants / gotchas (non-obvious; will bite you)

- **MetalLB is BGP-only, not L2** (M18/M36). Traefik VIP = `10.10.201.70`. Raw ICMP to
  VIPs fails by design; TCP works.
- **DNS = Technitium split-horizon** at `10.10.201.5` (k8s VIP) + `10.10.201.6` (VM
  fallback). It returns internal A + NODATA AAAA for `*.wind.etherport.net`. The UDM's
  own dnsmasq forwards to external upstreams (so it resolves internal names to the CF
  edge) — by design; everything that needs internal resolution uses Technitium.
- **Custom UDM firewall zones default intra-zone to BLOCK** (built-in Internal doesn't).
  Trusted = Servers/201, Management = 200. See `docs/architecture/firewall-zones.md`.
- **CF Access is edge-only** (enforced at Cloudflare via the tunnel), **not** at Traefik.
  Internal hits to `10.10.201.70` bypass CF Access.
- **Protect Alarm Manager webhooks** must use **IP-literal plain-HTTP** URLs
  (`http://10.10.201.70:8088/api/webhook/<id>`) — Protect's webhook client has a bug
  (`ERR_INVALID_IP_ADDRESS`) that breaks every hostname URL, and it validates TLS so
  https-by-IP fails too. Served by a dedicated Traefik `webhook` entrypoint. See
  the session-log + `platform/kubernetes/home-automation/ingressroute-webhook.yaml`.
- **Home Assistant automations are UI-managed** in `/config/automations.yaml` (in the
  PVC, not git). Run mode (`single`/`restart`/…) is YAML-only (HA's visual editor
  doesn't expose it). Editing/reloading an automation **cancels any in-flight run**.
- **kubespray `cluster.yml`/`--tags=cilium` breaks Cilium** by chowning `/opt/cni/bin`
  to `kube_owner` (`kube`); Cilium's `mount-cgroup` (root, `drop:[ALL]`, no DAC_OVERRIDE)
  then can't write there → `Init:CrashLoopBackOff` on the **next agent restart** (latent
  until then). **Run kubespray ONLY via `infra/kubespray/kubespray.sh`** — it auto-runs
  `pre-flight.yml` afterward to restore `root:root`. Real run path (venv, `--tags=cilium,download`)
  + full incident: `docs/runbooks/cilium-cni-dir-owner.md`. Cilium is **Helm-managed**
  (release `cilium`/kube-system), **not** Flux.
- **Cilium `policy-audit-mode` is ON** (H3 observation phase). IaC source of truth =
  `cilium_policy_audit_mode: true` in the kubespray inventory; toggle live via the
  `cilium-config` ConfigMap + `kubectl rollout restart ds/cilium` (read only at startup),
  NOT a raw kubespray run. H3 NetworkPolicy manifests in `platform/kubernetes/networkpolicies/`
  (enforcement is per-namespace opt-in via the `netpol.wind/enforced=true` label).
- **Cilium WireGuard encryption is ON** (M66, 2026-06-17). East-west **pod-to-pod**
  traffic is WireGuard-encrypted (`cilium_wg0`, full mesh, NodeEncryption off); was
  cleartext VXLAN before. IaC source = `cilium_encryption_enabled: true` +
  `cilium_encryption_type: "wireguard"` in the kubespray inventory. Cilium is a **Helm
  release** (`cilium`/kube-system) — apply config changes via `helm upgrade cilium
  --reuse-values --set …` (+ `rollout restart ds/cilium`), **not** a kubespray run
  (cni-owner landmine). Verify: `kubectl -n kube-system exec ds/cilium -c cilium-agent --
  cilium-dbg encrypt status`. Reverse: `--set encryption.enabled=false` + rollout restart.
- **The PVE host firewall (H37) MUST allow the Ceph storage VLAN → mon/OSD.** All K8s
  storage is **external Ceph on the `pve` host** (mon `10.10.210.41`, pool `k8s-ceph`),
  reached by the nodes over the dedicated **storage VLAN `10.10.210.0/24`** (`vmbr0.210`).
  H37's `policy_in: DROP` once shipped with **no Ceph rule** (2026-06-17) → existing RBD
  sessions survived via conntrack but every **new rbd map/create** from K8s was dropped —
  a *latent* break that only bit on a fresh map (node reboot / pod reschedule / new PVC)
  ~30h later (wedged technitium-1 + blocked provisioning). Fixed by the **`pve-ceph`
  security group** in `infra/terraform/proxmox/firewall/` (storage VLAN → `3300,6789,6800:7300`).
  **Never tighten the PVE host firewall without keeping that Ceph allow** or you silently
  break all future Ceph volume operations. Symptom: csi `DeadlineExceeded` / `exit 108`
  while `ceph -s` is `HEALTH_OK` locally on pve. Diagnose from pve: `ceph -s`, `rbd status
  k8s-ceph/<img>` (stale watchers), `ceph osd blocklist ls`.
  **The same gotcha bit the IPMI exporter** (M89, 2026-06-20): the H37 default-deny had no
  allow for the in-band `ipmi_exporter` `:9290`, so Prometheus's scrape was dropped →
  `TargetDown pve-ipmi`. Fixed by the **`pve-ipmi`** security group (`10.10.201.0/24` →
  `9290`). **The PVE host firewall now has THREE required allows — mgmt (`22,3128,8006`),
  Ceph (storage VLAN → mon/OSD), IPMI (`:9290` from the Servers/K8s VLAN); keep all three
  on any change.** Tell: a dropped allow gives connect **timeout** (SYN dropped), a dead
  service gives **refused** — use that to tell firewall-vs-process.
- **The bpg/proxmox provider (0.106) silently NO-OPs the VM `watchdog {}` block** (M91, 2026-06-20):
  `terraform apply` "succeeds" + may reboot the VM, but the i6300esb device never lands in the config —
  so the `watchdog.action: none→reset` shows as a **perpetual, unresolvable plan diff** (don't chase it
  with apply+reboots — they do nothing; verify the live VM config, not just "apply succeeded"). The
  k8s-vms VMs carry `lifecycle { ignore_changes = [watchdog] }` to suppress it. The watchdog is set the
  working way: **`qm set <vmid> --watchdog model=i6300esb,action=reset`** (host-side, PVE API/pvesh —
  config-only, **activates on the VM's next COLD start**, not a soft reboot) + the guest `watchdog`
  daemon (ansible `k8s-node-fixes.yml`). Also: a **VM graceful shutdown HANGS** if an un-drainable
  single-instance CNPG pod (PDB minAvailable=1, e.g. `cue-db`) sits on it (RBD won't unmount) — drain
  evicts what it can, then `kubectl delete pod` the PDB-blocked ones before any node reboot.

## 6. Maintenance rules (keep this memory alive)

**Docs are part of the change, not an afterthought.** Treat documentation like code:
if a change alters documented behavior, update the relevant docs **in the same change
(or an immediate follow-up commit)**. A change isn't done until its docs are current.
This applies to **everything** — not just the handoff files:
- **Component READMEs** (e.g. `infra/terraform/*/README.md`, `platform/kubernetes/*/README.md`)
  and the **root `README.md`** when structure/architecture/procedures change.
- **Runbooks** (`docs/runbooks/`) and **architecture docs** (`docs/architecture/`, e.g.
  `firewall-zones.md`) when the system or an operational procedure changes.
- The **`docs/README.md` index** when you add/move/retire a doc.
- Add **staleness banners** or **archive** (`docs/planning/archive/`, `docs/runbooks/archive/`)
  superseded docs instead of leaving contradictory ones (a stale doc is worse than none).

**Specifically, at the end of any substantive working session, before you stop:**
1. **Update `docs/planning/outstanding-work.md`** — flip status glyphs, add new items
   with the next free ID per tier, note what landed (commit SHAs help).
2. **Append an entry to `docs/planning/session-log.md`** — date, what you did, key
   decisions + *why*, current state, and explicit next steps. Newest at the top.
3. **Update all docs your change touched** per the principle above (READMEs, runbooks,
   architecture, indexes) — don't let the prose drift from reality.
4. **Update this `CLAUDE.md`** if the operating model, access, or an invariant changed
   (new gotcha, new credential, new convention). Keep it lean — link, don't duplicate.
5. **Save durable, non-obvious cross-session facts** to the user's Claude Code memory
   (`~/.claude/projects/.../memory/`) too, with a one-line pointer in its `MEMORY.md`.
6. Commit docs together with the change they describe (or as a follow-up commit). The
   mini auto-pushes `main`; docs/ and this file are **not** Flux-reconciled (Flux only
   watches `clusters/wind`), so committing them is purely for durable handoff.

> If you're a fresh agent: skim §1's four files, then check the newest
> `session-log.md` entry for the current frontier. That's enough to pick up.
