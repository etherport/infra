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
2. **`docs/guides/agent-operating-principles.md`** — the **operating charter**:
   change/verification/diagnosis/doc discipline, safety rails, when to ask the
   operator. **Binding for any agent, any model.**
3. **`docs/planning/outstanding-work.md`** — the **live to-do tracker**. Items keep
   stable IDs (`H29`, `M53`, `L21`…) across revisions so history is grep-able.
   Status legend: ✅ done · 🟡 in progress · ⏳ pending · 📋 drafted/awaiting apply.
4. **`docs/planning/session-log.md`** — **narrative journal** of what each working
   session did, why, and how to resume. Read the latest entries to know where we
   left off. This is the "pick up after a chat-history loss" artifact.
5. **`docs/README.md`** — index into `docs/{architecture,runbooks,operations,reference,setup,guides,planning}`.
6. User's Claude Code memory lives outside the repo, **per-machine**. On the **devbox**
   (where dev sessions run): `~/.claude/projects/-home-ubuntu-code-infra/memory/`
   (`MEMORY.md` + files); the mini has its own under `-Users-grahamsmith-code-infra/`.
   It holds operator preferences + cross-session facts. Repo `CLAUDE.md` is the
   in-repo equivalent that any agent (any tool, any machine) can read.

## 2. Repo map

```
clusters/wind/        Flux entrypoint — GitRepository/Kustomization, helm-releases/, image-automation/
platform/kubernetes/  Per-namespace manifests + helm values (Flux-managed)
infra/terraform/      TF stacks: proxmox/ aws/ unifi/ cloudflare/ google/ aws/github-oidc/
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
- **No `flux` CLI on the hosts (mini or devbox).** Trigger reconciles via annotation:
  ```bash
  kubectl annotate --overwrite -n flux-system gitrepository/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
  kubectl annotate --overwrite -n flux-system kustomization/flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)"
  kubectl annotate --overwrite -n flux-system helmrelease/<name>     reconcile.fluxcd.io/requestedAt="$(date +%s)"
  ```
  Watch `.status.lastAppliedRevision` / `.status.artifact.revision` to confirm.
- **Terraform** ships via GitHub Actions workflow_dispatch (CI uses GitHub→AWS
  **OIDC**, not static keys — H29; GCP uses **WIF** — L21). See README "How to apply".
- **Node OS patching:** `infra/ansible/playbooks/k8s-node-patch.yml` (rolling
  cordon/drain/`apt full-upgrade`/reboot-if-required/uncordon, `serial:1`, force-deletes
  PDB-blocked single-instance CNPG pods). Its kubectl steps are `delegate_to: localhost`.
  ⚠️ **There is NO HA API VIP** (`controlPlaneEndpoint` = the single cp1 `10.10.201.50`;
  workers use local `nginx-proxy`). So to patch a **control-plane** node, point the
  playbook at a *different* healthy CP: `-l k8s-cpN -e confirm=yes -e
  kubeconfig_path=<temp kubeconfig → another CP>`. Patch **cp1 LAST** (etcd leader +
  endpoint); verify etcd quorum (`etcdctl endpoint health --cluster`, `/etc/etcd.env`
  has the certs) between each. Full technique: session-log 2026-06-24 cont.7.
- **UDM/UniFi changes:** the **`ubiquiti-community/unifi` 0.41.25** TF provider (migrated off archived
  paultyng 2026-07-03 via state-rm+import — its schema is a REWRITE: nested `dhcp_server{}`, `vlan`,
  `unifi_client` not `unifi_user`, imports by MAC; use `UNIFI_API_KEY` locally — rapid logins trip the
  UDM rate-limiter; the fork FIXED paultyng's PUT-400 bug) covers networks/reservations/
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
  `sops`+age, `git`, `claude`, `terraform` 1.15.5 + `aws` CLI, `helm` v3.19 (/usr/local/bin — added 2026-07-02; cilium upgrades run from the devbox now, values snapshot in docs/reference/snapshots/).
  ✅ **TF is CI-only (M82, decided 2026-06-24): the devbox holds NO standing AWS/PVE creds.**
  Every TF stack runs via a GitHub Actions workflow (AWS via OIDC; proxmox/unifi/cloudflare
  on the self-hosted `lifecycle` runner with PVE/CF/UDM creds as **GH secrets**) — incl. the
  new `terraform-proxmox-firewall` workflow that closed the last gap. The devbox **dispatches**
  runs via the **Actions:write PAT (M92)** — small blast radius. The standing `~/.aws`
  `[homelab]` key was **removed 2026-06-24**; the AWS key + PVE token live only in SOPS
  (encrypted) + GH secrets. **Rare local-debug TF only:** re-render on demand with
  `scripts/render-aws-credentials.sh` (writes `~/.aws/[homelab]` from SOPS) +
  `scripts/tf-proxmox.sh <stack> <args>` (injects the PVE token) — then it's a throwaway, not
  standing. (The SOPS **age key** stays on the devbox — needed for headless `sops -d`.)
  **Still lacks:** a browser (headless-Chrome verification → mini/CI) and `gh` CLI (dispatch
  GH Actions via the M92 PAT/API, not `gh`). Auth: Claude OAuth is broken
  on headless Linux (GitHub #47152) → token transplanted from the mini's Keychain into
  `~/.claude/.credentials.json`. Provisioning: `infra/ansible/playbooks/devbox.yml`
  (+ `infra/devbox/README.md`).
- **Mac mini** (`10.10.202.101`, tailnet `100.79.165.113`) = always-on headless
  ops/RC host: full kubectl/terraform/sops/ansible, **no 1P at runtime**. Retained for
  macOS-only iCloud backups (the **cairn** agent, M103 — replaced the bash suite 2026-06-25;
  `docs/runbooks/cairn-deployment.md`) + as the TF/AWS-capable ops box. Procedure:
  `docs/setup/headless-ops-host.md`.
- **Appliances:** UDM Pro `10.10.200.1` (Network v2 API via `udm_api_key` `X-API-KEY`,
  or `udm_tfadmin_*` login). UniFi Protect = **`Windprotect` `10.10.212.10`** (SSH via
  `udm_ssh_user`/`udm_ssh_password`; integration API via `protect-tf` key but it's
  **read-only — Alarm Manager automations are UI-only**). UNAS `10.10.209.10`.
- **SSH to the Ubuntu fleet is CERT-ONLY (M76, since 2026-06-26).** All 15 hosts (8 k8s nodes +
  5 standalone VMs + step-ca + pve) trust the **step-ca user CA** (`TrustedUserCAKeys`, VM 1006
  `https://10.10.201.46:8443`); the standing `automation@homelab` static key was **removed from every
  running host's `authorized_keys`** and is now **rejected**. The **devbox** mints a 13h user cert via
  the renew-loop (`step-ssh-renew.timer` → `~/.ssh/id_homelab_cert`, ssh-config is cert-only — just
  `ssh user@host`); **CI** mints a ≤1h cert per run (`setup-ssh-cert` action + `STEP_JWK_PASSWORD`).
  ⚠️ The static key SURVIVES in **cloud-init as the per-host BOOTSTRAP seed** (a new host must be
  reachable to be enrolled, then `step-ca-remove-static-key.yml` strips it — the 3 TF vars are annotated)
  + **packer** (build VM) + **appliance** scoped keys. **Break-glass = PVE console + IPMI
  `10.10.200.21`** (if a cert expires with step-ca down). Host certs (`HostCertificate`) kill known_hosts
  TOFU on the 13 Servers-VLAN hosts. Detail: `docs/planning/archive/m76-ssh-shortlived-plan.md`.
- **Never delete the `terraform-homelab` IAM access key** — it's shared with the local
  homelab profile (H29 cutover note); rotate-only. (It is NOT one of the M75-orphaned keys.)
- **M75 IRSA (in-cluster AWS workload identity) — DONE + e2e-verified 2026-06-24.** All in-cluster
  workloads (velero, the s3-sync family, CNPG barman ×2, ai-advisor, cloudwatch-to-loki) now get
  short-lived AWS creds via `AssumeRoleWithWebIdentity`; **no static AWS keys in etcd.** Pieces:
  TF stack `infra/terraform/aws/cluster-irsa/` (CI `terraform-cluster-irsa.yml`) = IAM OIDC provider
  + 5 least-priv roles `wind-irsa-{velero,s3-sync,barman,cloudwatch-read,cue-media}` + a **deliberately PUBLIC**
  S3 bucket `wind-cluster-oidc-830881980142` (the issuer — serves the OIDC discovery doc + the
  cluster's *public* SA signing keys; public-read is **by design, not a leak**). The kube-apiserver
  `--service-account-issuer` = that bucket URL (**single issuer**), `--api-audiences` pinned;
  **persisted** in the kubespray inventory (`kube_control_plane.yml` `kube_kubeadm_apiserver_extra_args`)
  AND the live manifests match it (zero drift). Injection is **manual token projection (no webhook)** —
  each workload mounts a projected SA token (aud `sts.amazonaws.com`) + `AWS_ROLE_ARN`/`AWS_WEB_IDENTITY_TOKEN_FILE`;
  CNPG via the Cluster CR's `projectedVolumeTemplate`+`env` (`/projected/token`). ⚠️ **GOTCHAS if you
  touch this:** (1) `--api-audiences` defaults to the FIRST `--service-account-issuer` → changing the
  issuer without pinning api-audiences 401s every in-cluster token; (2) after a kubespray run, confirm
  the apiserver issuer is the bucket URL + IRSA still assumes a role; (3) aws-CLI workloads need
  `HOME=/tmp` (uid-1000 `/.aws` cache); (4) velero Kopia-maintenance Jobs need `AWS_REGION`;
  **(5) ⚠️ changing `--service-account-issuer` BREAKS MULTUS** — it bakes its kubeconfig token to a
  file once at pod start + never refreshes, so the old `iss` is rejected → `multus … Unauthorized`
  → no new pod schedules cluster-wide (2026-06-25 incident, ~7h). **FIX: `kubectl -n kube-system
  rollout restart ds/kube-multus-ds-amd64`** after ANY issuer change. ⏳ Only
  follow-up: deactivate/remove **4 orphaned dedicated IAM keys** (key material still in git history +
  Active in AWS) via their TF stacks. **SES SMTP secrets stay static** (protocol). **etcd-backup is
  host-level (CP systemd), NOT an IRSA target** → [[M71]]. Full detail: `docs/runbooks/irsa-workload-identity.md`.

## 5. Key invariants / gotchas (non-obvious; will bite you)

- **⚠️ Connectivity is gated at FOUR independent layers (post-2026-06 hardening).** When a
  route/service breaks, or when you add/move one, check ALL of them — a drop at any single
  layer looks identical from the client: (1) **UDM zone firewall** (custom zones default
  intra-zone BLOCK; Trusted=201, Management=200); (2) **PVE host firewall** (H37 default-deny
  — keep its FOUR allows: mgmt, Ceph storage-VLAN, IPMI, node_exporter); (3) **Cilium NetworkPolicy tiers**
  (6 enforced; allow CONTAINER not service ports); (4) **CF Access (edge) + Authentik
  forward-auth (internal apps)**. Each is detailed below. Tell **timeout** (firewall SYN
  drop) from **refused** (dead process) to localize fast.
- **MetalLB is BGP-only, not L2** (M18/M36). Traefik VIP = `10.10.201.70`. Raw ICMP to
  VIPs fails by design; TCP works. **A VLAN-201 host (incl. the devbox, and TS/WG remote
  clients that egress via a VLAN-201 subnet-router/`vpn-fallback`) CANNOT reach a BGP VIP**
  (no L2 → ARP fails); only off-subnet clients via the UDM (which holds the `/32` BGP route)
  reach them. Use the `.6` Technitium VM fallback or a `/32 via .1` route. Memory:
  `vlan201-host-cant-reach-metallb-vip`.
- **⚠️ MetalLB is now Helm/Flux-managed in FRR mode (L24, 2026-06-28) — NOT the kubespray addon.**
  `metallb_enabled: false` in kubespray; the engine is `clusters/wind/helm-releases/metallb.yaml`
  (chart 0.14.x, `speaker.frr.enabled=true`, `crds: Skip`), CRs in `platform/kubernetes/metallb/`.
  Change it via the **HelmRelease**, never kubespray (a kubespray run won't re-add it, but don't
  re-enable the native addon — it'd fight). The MetalLB↔UDM eBGP session is **TCP-MD5-authenticated**
  (`BGPPeer.spec.passwordSecret: bgp-md5` ↔ UDM peer-group `metallb` `neighbor … password`; FRR-mode
  only). A mismatch on either end drops ALL sessions → VIP/ingress/DNS withdrawal (no L2 fallback) —
  the `MetallbBGPAllSessionsDown` alert (`metallb_bgp_session_up`) now catches that. Migration detail:
  `docs/planning/archive/l24-metallb-frr-migration-plan.md`.
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
  until then). **Run kubespray ONLY via `infra/kubespray/kubespray.sh`** (now from the **devbox**: venv
  `~/.kubespray-venv`, `KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert` — the wrapper default is the removed
  static key; run long upgrades in **detached tmux**, harness background tasks get killed; version
  overrides past the shipped checksums = the SCALAR e.g. `containerd_archive_checksum`, role vars beat
  inventory dicts; `--limit` retries must NOT include already-upgraded CPs — kubeadm re-apply fails +
  leaves them cordoned; pre-arm a cue-db PDB drain watch on its CURRENT node) — it auto-runs
  `pre-flight.yml` afterward to restore `root:root`. Real run path (venv, `--tags=cilium,download`)
  + full incident: `docs/runbooks/cilium-cni-dir-owner.md`. Cilium is **Helm-managed**
  (release `cilium`/kube-system), **not** Flux.
- **Cilium `policy-audit-mode` is OFF — policies ENFORCE** (since 2026-06-22; was the H3
  observation phase 06-15→06-22). IaC source of truth = `cilium_policy_audit_mode: false`
  in the kubespray inventory; toggle live via the `cilium-config` ConfigMap + `kubectl
  rollout restart ds/cilium` (read only at startup), NOT a raw kubespray run. ⚠️ patch +
  rollout as SEPARATE commands (the compound one trips the auto-mode classifier). H3
  NetworkPolicy manifests in `platform/kubernetes/networkpolicies/`; enforcement is
  **per-namespace opt-in via the `netpol.wind/enforced=true` label** — **all 6 enforced tiers:
  `postgres`, `cue`, `dns`/Technitium, `traefik`, `monitoring`, `authentik`** (the original 5 H3
  target tiers + `authentik` added as tier 6, M115 2026-07-01 — SSO IdP; each allowlist
  built+verified from Hubble/audit data, 0 drops). **All unlabeled namespaces stay allow-all.**
  (dns query ports open to `all`, `:5380` admin in-cluster only; traefik + monitoring egress
  permissive — `cluster` any-port + enumerated `world` ports — so scrapes/routes never cut;
  traefik/monitoring labelled via the `namespace-pss-labels.yaml` patch since Helm-created.)
  **DROP alerting is LIVE:** export carries `verdict:[AUDIT,DROPPED]` → Loki `{job="hubble-audit"}`
  → loki-ruler rules in `platform/kubernetes/monitoring/06-loki-rules-cilium-audit.yaml`:
  `CiliumNetpolDropFlow` (IN-CLUSTER drop to/from an enforced ns = "open a channel") +
  `CiliumTraefikIngressDrop` (**critical**; any drop to traefik on a PUBLIC entrypoint
  container port `:8000/:8443/:8088` — these must accept `world`, so a drop = ingress/VIP
  reachability bug; added after the 06-23 outage so a future external→VIP netpol break
  alerts in ~10m instead of staying silent). Adding a service that crosses an enforced
  boundary → update the per-tier CNP; see `docs/runbooks/networkpolicy-tiers.md`. To add a
  NEW tier, toggle audit on first. NB GAP: `CiliumNetpolDropFlow` excludes `world` sources
  (scan noise), so a wrongly-dropped EXTERNAL client to a NON-traefik enforced tier still
  won't auto-alert — find those with `hubble observe --verdict DROPPED`.
  ⚠️ **Audit is a single GLOBAL
  switch**, so to add a new tier you must briefly flip audit back ON (ConfigMap+rollout),
  label + observe the new namespace via Loki `{job="hubble-audit"}`, build its allowlist
  until clean, then flip OFF again. See `platform/kubernetes/networkpolicies/README.md`.
  🆕 **Operational tax — adding/changing a service:** if a new workload is IN an enforced
  namespace, or (in any namespace) needs to REACH one (e.g. a new app using the shared
  `postgres`), you MUST update that tier's `1x-tier-<ns>.yaml` allowlist in the same change
  or its traffic is silently dropped (no alert yet). Unlabeled↔unlabeled needs nothing.
  Procedure + `hubble observe --verdict DROPPED` detection: `docs/runbooks/networkpolicy-tiers.md`.
  ⚠️ **A tier allowlist must permit CONTAINER (target) ports, not SERVICE ports** — Cilium
  enforces ingress at the destination pod, and kube-proxy DNATs the Service/MetalLB-VIP port
  → pod `targetPort` BEFORE policy applies, so listing the svc port silently drops the flow.
  (Caused a ~16h Traefik-VIP outage 2026-06-23 — svc `:443`→pod `:8443`; fix `1a98eee`, now
  guarded by the `CiliumTraefikIngressDrop` alert.) Map with `kubectl get svc -n <ns> <svc>
  -o jsonpath=...{.targetPort}`; debug a VIP drop via `cilium-dbg monitor --type drop` on the
  **pod IP + container port** (the VIP is gone post-DNAT); and exercise the real `world`→VIP
  path when validating "0 AUDIT → enforce". Full detail: `docs/runbooks/networkpolicy-tiers.md`.
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
  `9290`). **The PVE host firewall now has FOUR required allows — mgmt (`22,3128,8006`),
  Ceph (storage VLAN → mon/OSD), IPMI (`:9290` from the Servers/K8s VLAN), node_exporter
  (`:9100` from the Servers/K8s VLAN — H42, 2026-07-01; deployed by the standalone
  `node-exporter.yml`, NOT base.yml — base.yml's Automatic-Reboot is a hypervisor hazard);
  keep all four on any change.** Tell: a dropped allow gives connect **timeout** (SYN dropped), a dead
  service gives **refused** — use that to tell firewall-vs-process.
- **The bpg/proxmox provider (0.106) silently NO-OPs the VM `watchdog {}` block** (M91, 2026-06-20):
  `terraform apply` "succeeds" + may reboot the VM, but the i6300esb device never lands in the config —
  so the `watchdog.action: none→reset` shows as a **perpetual, unresolvable plan diff** (don't chase it
  with apply+reboots — they do nothing; verify the live VM config, not just "apply succeeded"). The
  k8s-vms VMs carry `lifecycle { ignore_changes = [watchdog] }` to suppress it. The device is now
  attached host-side via `qm set <vmid> --watchdog model=i6300esb,action=reset` (PVE API; surfaces in
  the guest as a PCI device on the VM's next COLD start) — **BUT the watchdog still does NOT work: the
  `i6300esb` kernel module is ABSENT from the node kernel** (`6.8.0-124-generic` has only `softdog` +
  `wdat_wdt`; even `linux-modules-extra` lacks it), so `/dev/watchdog0` never appears and the guest
  daemon is inert. **The hardware watchdog has never armed; it's BLOCKED pending the module** (M91). Do
  NOT add a `modprobe i6300esb` task — it FATALs the k8s-node-fixes playbook. **Verify a kernel module
  exists before attaching watchdog devices + rebooting nodes** (this lesson cost ~7 reboots + 3
  incidents). Also: a **VM graceful shutdown HANGS** if an un-drainable single-instance CNPG pod (PDB
  minAvailable=1, e.g. `cue-db`) sits on it (RBD won't unmount) — drain evicts what it can, then
  `kubectl delete pod` the PDB-blocked ones before any node reboot.
- **Authentik is the SSO IdP** at **`auth.wind.etherport.net`** (goauthentik 2024.12, embedded outpost;
  shared HA postgres DB). It now gates internal apps (kills "internal = trusted", H38). **OIDC** apps
  (Grafana, wiki.js, Open WebUI) + a domain-level **forward-auth** proxy provider gating the browser
  admin UIs (Proxmox/IPMI/PDU/UPS/Technitium DNS/Traefik dashboard) via the Traefik
  `authentik-forward-auth@authentik` middleware. **Left ungated by design:** HA + Plex (own auth;
  forward-auth breaks HA mobile/API/webhooks + external CF logins), and loki/pushgateway/ollama
  (machine APIs — UDM-firewall-scoped). Config = blueprints in `platform/kubernetes/authentik/40-blueprints.yaml`
  (auto-applied by the worker; secrets via `!Env`). **Footguns:** (1) NEVER put `password:` in a user
  blueprint — Authentik re-applies it on EVERY apply (write-only, can't diff) and clobbers UI-set
  passwords on each worker restart; manage human passwords/passkeys in the UI (akadmin = break-glass).
  (2) Grafana literal `role_attribute_path: 'GrafanaAdmin'` evaluates EMPTY (go-ini strips the quotes)
  → roles reset to Viewer each login; we use `skip_org_role_sync: true` + manual server-admin grant.
  (3) Dark theme = brand `attributes.settings.theme.base=dark` (no UI toggle in 2024.12). Full pass +
  rationale: H38 in outstanding-work + session-log 2026-06-23 (cont. 3).
- **Kyverno admission policies ENFORCE (M73, since 2026-06-28) — they reject manifests.** Three
  cluster policies in `platform/kubernetes/kyverno/` (per-rule `validate.failureAction: Enforce`):
  `disallow-latest-tag` + `require-image-tag` → **a workload with a `:latest` or untagged image is
  DENIED at admission** (pin a tag/digest), and `require-resource-requests` → containers need CPU/mem
  requests. A **mutate** `add-default-resource-requests` auto-injects a tiny default (10m/32Mi) on any
  container missing one *before* the validate webhook, so the requests rule rarely bites (third-party
  sidecars/dynamic pods get the default) — **the gotcha that bites is `:latest` → rejected.** Renovate
  pins digests, so most images are fine; hand-written manifests must carry a real tag. README:
  `platform/kubernetes/kyverno/README.md`.
- **Tetragon runtime detection is OBSERVE-ONLY (M74, since 2026-06-28) — it blocks NOTHING.** eBPF DS
  on all 8 nodes (`tetragon` ns; pods **2/2** = `tetragon` + `export-stdout` — correct for v2, not a
  bug). 4 cluster `TracingPolicies` (`monitor_only`): cred-file-access, setuid-root, ptrace-inject,
  pivot-root → Loki alerts `TetragonCredFileAccess`/`TetragonSetuidRoot`/…. ⚠️ The stdout export is
  **allowlist-limited** (`PROCESS_EXEC/EXIT` excluded — that's the ~1.1M-events/day firehose) to spare
  single-binary Loki; **don't widen `tetragon.exportAllowList`** or you flood it. README:
  `platform/kubernetes/tetragon/README.md`.

- **WireGuard HA (pod-primary) + the VRRP/PVE-firewall landmine.** VIP `10.10.201.20` floats
  between the K8s WG pod (prio 150, `preempt_delay 300`, promotion gated on wg health) and the
  **vpn-fallback** VM (prio 100; starts wg0 only on promotion — ~9s takeover, drilled 2026-07-03).
  ⚠️ **A default-deny PVE VM firewall silently breaks VRRP** (IP proto 112 is not a "port" — M77's
  DROP made vpn-fallback deaf to the pod's adverts → persistent VIP SPLIT-BRAIN + ARP-race blackhole
  of all UDM-routed AWS traffic). vpn-fallback now has an explicit proto-112 allow; when adding
  default-deny to ANY host, enumerate the control-plane protocols it participates in (VRRP, IGMP,
  etc.), not just TCP/UDP service ports. Symptom: keepalived logs "forcing new election" every second
  + both nodes hold the VIP; clients then need `ip neigh flush` (stale ARP). Also: the pod's HOST_IP
  script must exclude the VIP (a startup race CrashLooped it for 20h — fixed 07-03).

## 6. Maintenance rules (keep this memory alive)

**Docs are part of the change, not an afterthought** (charter D1 — the full operating discipline lives in `docs/guides/agent-operating-principles.md`; this section is the doc-maintenance subset). Treat documentation like code:
if a change alters documented behavior, update the relevant docs **in the same change
(or an immediate follow-up commit)**. A change isn't done until its docs are current.
This applies to **everything** — not just the handoff files:
- **Component READMEs** (e.g. `infra/terraform/*/README.md`, `platform/kubernetes/*/README.md`)
  and the **root `README.md`** when structure/architecture/procedures change.
- **Runbooks** (`docs/runbooks/`) and **architecture docs** (`docs/architecture/`, e.g.
  `firewall-zones.md`) when the system or an operational procedure changes.
- The **`docs/README.md` index** when you add/move/retire a doc.
- Add **staleness banners** or **archive** (`docs/planning/archive/`, `docs/runbooks/archive/`,
  `docs/architecture/archive/`) superseded docs instead of leaving contradictory ones (a stale doc
  is worse than none).
- **Current-state vs migration-history split (the standard for service docs).** A live reference doc
  describes the system **as it is now** — not the chronology of how it got there. When a doc accretes
  migration narrative ("since the BGP migration", "Phase 4 superseded by…", dated "added 2026-…"
  asides), move that narrative to a sibling `archive/<topic>-migration-history.md` (newest-first,
  with the "why/when" + superseded designs), leave the live doc current-state-only with a one-line
  "Migration history → see archive" pointer, and index both in `docs/README.md`. Exemplar:
  `docs/architecture/firewall-zones.md` + its `archive/firewall-zones-migration-history.md` (2026-06-30).
  Apply this incrementally to other service docs as you touch them.

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
   headless agent hosts (devbox — M81) auto-push `main`; docs/ and this file are **not** Flux-reconciled (Flux only
   watches `clusters/wind`), so committing them is purely for durable handoff.

> If you're a fresh agent: skim §1's files (charter included), then check the newest
> `session-log.md` entry for the current frontier. That's enough to pick up.
