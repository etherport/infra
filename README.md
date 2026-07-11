# homelab-infra

Single source of truth for the `wind` site: Proxmox host + K8s cluster +
non-K8s VMs + AWS (us-west-2) + UniFi network + Cloudflare zone.
Everything is in here — Terraform, Ansible, Kubespray inventory, Flux
manifests, Helm values, runbooks. If it's not in git, it doesn't
survive a rebuild.

## What's here

```
infra/terraform/     TF projects (proxmox/, aws/, unifi/, cloudflare/, google/, aws/github-oidc/)
infra/ansible/       Playbooks for Proxmox host + standalone VMs + UDM
infra/kubespray/     Kubespray submodule + wind inventory
infra/packer/        Ubuntu 24.04 cloud-init template build (VM 9001)
infra/tailscale/     Tailscale ACL policy (managed via tailscale-policy.yml workflow)
infra/ci/            Container image source for the ansible-runner used by gh-runner
platform/kubernetes/ Per-namespace Flux Kustomizations + helm values
clusters/wind/       Flux entrypoint: helm-releases/, image-automation/, kustomization.yaml
docs/                Architecture + runbooks + planning + setup guides
scripts/             Ad-hoc helpers (safety-check, service-status inventory drift)
```

## Architecture (high-level)

```
                 Internet
                    │
        ┌───────────┼────────────────────┐
        │           │                    │
 Cloudflare       CF Tunnel        AWS SES / Lambdas
 etherport.net    (CF Access SSO   (us-west-2)
  (authoritative   in front of                │
   since 2026-05)  in-cluster svcs)           │
        │                │                    │
   ┌────┴────────────────┴────────────────────┴────┐
   │             site-to-site WireGuard            │
   │  AWS edge box `private-infra_edge` (the ONLY  │
   │  standing EC2; host `vpn-aws`, 10.10.100.10)  │
   │  WG + Tailscale + Technitium ⇄ K8s wg pod     │
   │  VRRP backup: vpn-fallback (10.10.201.15)     │
   └──────────────────────────┬────────────────────┘
                              │
   ┌──────────────────────────┼────────────────────────────┐
   │  wind site (Proxmox `pve.wind.etherport.net`)         │
   │                                                       │
   │  K8s cluster v1.35.0 (Kubespray, Cilium CNI + Multus) │
   │    cp1-3 .50-.52  ·  w1-4 .53-.56  ·  gpu1 .60        │
   │    VLAN 201 primary  ·  VLAN 210 Ceph (MTU 9000)      │
   │    VLAN 202/204/205 secondary via Multus              │
   │                                                       │
   │  Standalone VMs (Ansible-managed)                     │
   │    dns-fallback .6   technitium (failover)            │
   │    vpn-fallback .15     WG VRRP backup                   │
   │    gh-runner   (VM 1003) self-hosted GH Actions       │
   │    step-ca .46 (VM 1006) SSH cert authority (M76)     │
   │    asterisk-sbc      Twilio⇄UniFi Talk SIP bridge     │
   │                                                       │
   │  Appliances (UniFi via terraform-unifi + UDM Ansible) │
   │    UDM Pro .200.1  ·  Protect .212.10  ·  UNAS .209.10│
   │    Switches: USW-Pro-Max-48-PoE, USW-Aggregation      │
   │    Probed by blackbox-exporter for status email/dash  │
   └───────────────────────────────────────────────────────┘
```

## Headless dev + ops hosts

The **Claude Code dev sessions** run on the **devbox** (`10.10.201.45`, tailnet
`100.74.216.102`) — an always-on Linux host that auto-resumes per-repo `claude
--continue` tmux sessions across reboots. It has the `terraform` 1.15.5 + `aws`
binaries plus `kubectl`/`sops`+age/`git`, but holds **no standing AWS/PVE creds**
(M82) — TF is **CI-only**; rare local-debug TF is a throwaway, re-rendering creds
on demand via `scripts/render-aws-credentials.sh` + `scripts/tf-proxmox.sh`. It
reconciles the cluster headlessly. Provisioned by `infra/ansible/playbooks/devbox.yml`
(+ `infra/devbox/README.md`).

**SSH to the whole fleet — including the AWS edge box — is cert-only (M76):** every
host trusts the step-ca user CA (VM 1006); the devbox auto-renews a 13h user cert
(`~/.ssh/id_homelab_cert`) and CI mints a ≤1h cert per run. The old static
`automation@homelab` key is rejected everywhere (it survives only as the cloud-init
bootstrap seed for rebuilding a host). Break-glass = PVE console + IPMI.

An always-on **Mac mini** (`10.10.202.101`, tailnet `100.79.165.113`) is the
secondary, macOS-only ops host — full kubectl/terraform/sops/ansible with **no
1Password at runtime** (age key + on-disk SSH keys; AWS creds rendered from SOPS
via `scripts/render-aws-credentials.sh`). It's retained for macOS-only iCloud
backups and as the browser/`gh`-capable TF/AWS ops box. It's a trusted admin
client on Clients/202 with a scoped UDM allow into the Management zone
(`trusted-admin-clients → Management` in `udm-firewall.yml`). Setup + design:
[`docs/setup/headless-ops-host.md`](docs/setup/headless-ops-host.md).

## Flux-managed components

Reconciled from `clusters/wind/kustomization.yaml`. Adding a new
namespace = add a directory under `platform/kubernetes/`, then
list it in the cluster kustomization.

**Helm releases** (`clusters/wind/helm-releases/`):
cert-manager · cnpg (postgres operator) · gpu-operator · kured ·
kube-prometheus-stack (`monitoring.yaml`) · loki (single-binary) ·
alloy (log collector + syslog ingester) · pushgateway · metrics-server · traefik ·
velero · tailscale-operator + tailscale-connector ·
github-actions-runner · kyverno (admission policy — both guardrails enforcing, M73) ·
tetragon (observe-only eBPF runtime detection, M74) ·
metallb (FRR mode, BGP + TCP-MD5 to UDM, L24).

All 17 HelmReleases are **exact-pinned** to the deployed chart version (no semver
ranges — ranges silently froze majors) and updated by Renovate's `flux` manager
(M122); majors arrive as individual PRs. Cilium is the exception: **Helm-managed
directly, not Flux** (release `cilium`/kube-system, upgraded from the devbox — see
`docs/runbooks/cilium-upgrade.md`).

**Kustomization-only** (no Helm): technitium · ceph-csi ·
authentik (SSO IdP + forward-auth, H38/M115) ·
garage (velero primary backup S3 — metadata on RBD, blocks on NAS NFS, M137) ·
velero-dr (weekly Garage→S3 Deep Archive mirror + pve-config offsite, M137/M130) ·
auto-remediation (+ auto-remediation-rbac) · cloudflared · blackbox-exporter ·
cloudwatch-to-loki · policy-baseline · cnpg (Cluster CR) ·
home-automation · plex · rclone-gdrive · rclone-onedrive · unas-health · wikijs · ollama ·
cue-api + cue-db (CNPG) · unifi-poller ·
tailscale (subnet router) · wireguard · cloudflare-ddns · unifi-backup ·
unifi-cert-sync · monitoring (alerts, dashboards, status report,
aws-cost-exporter — daily AWS cost/forecast → Grafana + status email, M136) ·
ntfy (M132 — 2nd critical-alert channel: Alertmanager severity=critical → am2ntfy bridge → phone, tailnet-only) ·
backups (Velero schedules + 7 s3-sync shares + daily report).

`clusters/wind/kustomization.yaml` is the readable index — comments
inline explain *why* each include is there.

## AI alert advisor (`auto-remediation` namespace)

The big surface area. Static rule-based remediation (21 rules in
`configmap.yaml`) is the floor; on top of that sits a 3-phase AI
advisor that diagnoses + acts on alerts the static rules miss.

| Phase | What it does | State |
|---|---|---|
| Phase 1 | Email-only diagnosis (advisor reads alert + Prometheus + Loki + CW logs, emails proposal) | Live |
| Phase 2 | Diagnosis email includes Approve/Reject buttons (HMAC-signed URL → controller executes) | Live |
| Phase 3 | Autonomous execute for alerts opted in via `ai_remediation: "auto"` label | Live |

**19 action types** across 3 tiers (declared in
`platform/kubernetes/auto-remediation/advisor-prompt-configmap.yaml`):

- **Tier 1 — pod/deploy mechanics** (low-risk, executable):
  `restart_pods`, `scale_deployment_temp`, `delete_completed_jobs`,
  `delete_evicted_pods`, `rollout_restart`, `noop`.
- **Tier 2 — workload-aware** (medium-risk, mostly approve-via-email):
  `trigger_velero_backup_now`, `trigger_cnpg_backup_now`,
  `force_cert_renewal`, `silence_alert_temporarily`, `expand_pvc`,
  `pause_cronjob`/`unpause_cronjob`, `rollback_deployment`,
  `cnpg_recreate_replica`, `bump_resource_request`.
- **Tier 3 — host-level via SSH** (Phase 3 SSH advisor):
  `prune_host_logdir` (auto), `restart_systemd_unit` (approve-only),
  `journal_vacuum` (auto). Key in
  `platform/kubernetes/auto-remediation/advisor-ssh-key.sops.yaml`;
  pubkey deployed to dns-fallback / vpn-fallback / the AWS edge box (`vpn-aws`).

**Closed-loop verification**: after every auto-execute or approve-execute,
controller schedules a check N min later that re-queries the original
alert. Outcome emitted as `verification_passed` / `verification_failed`
/ `verification_uncertain` audit events. Failed verifications email
the operator with a "the action did not clear the alert" notice.

**Cross-session memory**: each advisor invocation reads recent prior
attempts on the same alertname (last 14d from Loki audit log) +
their verification outcomes. Surfaces in the Claude prompt as "tried
restart_pods 3x in last 7d, 0 cleared the alert" — discourages
proposing actions known not to work, prioritizes asking for human
investigation when patterns repeat.

**Deep mode** (`ai_advisor_mode: "deep"` on the alert): multi-turn
tool-use loop where Claude can call `promql_query`, `loki_query`,
`kubectl_describe` etc. inline before committing to a proposal.
Currently opted-in by `CNPGBackupFailed`; expand selectively for
genuinely-mysterious failures (deep mode burns ~3-5x the tokens
of single-shot).

**AWS context (M45 Phase B)**: advisor pulls CloudWatch log groups
for AWS-side alerts (Lambda function logs, EC2 cw-agent logs).
Reuses the `ai-advisor-readonly` IAM user. Heuristic-triggered
(`labels.job==external-nodes`, `instance starts with 10.10.100.`,
`alertname contains "lambda"`).

Per-phase enable runbooks (historical): `docs/runbooks/archive/ai-advisor-phase{1,2,3}-enable.md`
+ `archive/ai-advisor-phase-b-cloudwatch.md`. Coverage map:
`platform/kubernetes/auto-remediation/COVERAGE.md`. Spec:
`docs/planning/archive/ai-alert-remediation-2026-05-23.md`.

## Monitoring + observability

| Layer | Tool | Lives in |
|---|---|---|
| K8s metrics | kube-prometheus-stack (Prom + Alertmanager + Grafana, replicas=2 with podAntiAffinity) | `clusters/wind/helm-releases/monitoring.yaml` |
| Alerts (custom) | PrometheusRule CRDs | `platform/kubernetes/monitoring/0[1-6]-*.yaml`, `comprehensive-alerts.yaml`, `dns-health-alerts.yaml` |
| Logs (all) | Loki single-binary + Alloy DaemonSet | `clusters/wind/helm-releases/loki.yaml`, `alloy.yaml` |
| Syslog | Alloy syslog receiver (UDM, switches, BMC) | Alloy config in same HR |
| AWS logs | `cloudwatch-to-loki` 5-min CronJob (boto3 → Loki push) | `platform/kubernetes/cloudwatch-to-loki/` |
| Appliance probing | blackbox-exporter (ICMP + HTTPS on UDM/Protect/UNAS) | `platform/kubernetes/blackbox-exporter/` |
| Daily digest | service-status-report CronJob → email + HTML dashboard | `platform/kubernetes/monitoring/service-status-report/` |
| BMC IPMI | ipmi_exporter scrape + ipmievd → Alloy syslog | covered by M40 |

Grafana: `https://grafana.wind.etherport.net` (admin pw in 1P or
via `docs/runbooks/grafana-admin-password.md`).

## Backups

| What | Tool | Destination | Schedule |
|---|---|---|---|
| K8s resources + PVs | Velero (12 schedules) | **Garage** — local S3-on-NAS (`garage.garage.svc:3900`, metadata on Ceph-RBD + data on the NAS/NFS) via Kopia — **primary** (M137, 2026-07-08) | daily |
| ↳ K8s backups — offsite DR | `rclone velero-dr-sync` | S3 `velero.wind.etherport.net/dr/` → Glacier Deep Archive | weekly (Sun) |
| ↳ old S3 Velero repo | (read-only) | S3 `velero.wind.etherport.net` — `accessMode:ReadOnly`, pre-07-08 restore points aging out at 30-day TTL | — |
| Postgres | CNPG Barman (WAL + base) | S3 `postgres-barman.wind.etherport.net` (dedicated bucket) | continuous + daily base |
| etcd | systemd timer per CP + Velero `kube-system-daily` ships `/var/lib/etcd-snapshots` | local + S3 | daily 02:00 PT |
| pve `/etc/pve` + Ceph MON store | `pve-config-backup.timer` (M130) → NAS `/mnt/pve/sequoia-backups/pve-config/`, then `pve-config-offsite` CronJob → S3 `velero…/pve-config/` | NAS + S3 (3-2-1) | daily 03:30 / 04:15 PT |
| UDM controller-db + UDM/Protect core-config | `unifi-backup` CronJob | S3 `infra.wind.etherport.net/unifi/` | daily 04:00 PT |
| NAS shares (7) | `s3-sync` CronJob per share | per-share S3 buckets | daily 01:00 PT |
| Google Drive | `rclone gdrive-sync` CronJob | NFS `/mnt/data/gdrive-mirror` | hourly (:00) |
| OneDrive | `rclone onedrive-sync` CronJob | NAS `Backups/Graham/OneDrive` → S3 | hourly (:30) |

Backup alerts in `platform/kubernetes/monitoring/06-backup-alerts.yaml`.
Restore procedures + RTO/RPO targets:
`docs/runbooks/disaster-recovery.md` §10 (ownership matrix) + §11
(drill rotation).

## Networking

| Layer | Detail |
|---|---|
| Node VLAN | 201 (10.10.201.0/24) — kubelet, API, pod underlay |
| Storage VLAN (Ceph) | 210 (10.10.210.0/24) — Ceph mon at 10.10.210.41, MTU 9000, K8s nodes via `enp6s22` |
| Storage VLAN (NAS NFS) | 209 (10.10.209.0/24) — kubelet NFS to the UNAS (`sequoia` 10.10.209.10), MTU 9000, on NAS-workload nodes w1–w4 + gpu1 via `enp6s23` (DHCP .100–.104). Added 2026-05-29 (BGP Phase A) to keep NFS on the switch fabric ahead of 201→UDM-routed. **UNAS NFS export ACL must list these 209 IPs** (UI-managed, not IaC). |
| Multus parents | 202 (client), 204 (IoT), 205 (security) — `enp6s19/20/21` per K8s node, NADs in `platform/kubernetes/multus/` |
| Proxmox SDN | Per-VLAN bridges: `servers`(201), `clients`(202), `iot`(204), `security`(205), `vsan`(209), `guest`(206), `unifi`(212). Standalone VMs migrated 2026-05-18. K8s VM migration in `infra/terraform/proxmox/sdn/` |
| Firewall zones (UDM) | M56 (2026-05-31): **Trusted**={Servers/201}, **Management**={200, contained — device/admin plane}, Internal={Default/199}; plus IoT/Security/Infrastructure custom zones. See [`docs/architecture/firewall-zones.md`](docs/architecture/firewall-zones.md) |
| UniFi IaC | `infra/terraform/unifi` on the **`ubiquiti-community/unifi`** provider 0.41.x (M125, 2026-07-03 — the retired `paultyng/unifi` is replaced; new schema: nested `dhcp_server{}`, `unifi_client`, gateway-style subnets). Auth via `UNIFI_API_KEY` (avoids UDM login rate-limit). Cardinal rule: plan must be `No changes` before apply. |
| LoadBalancer | MetalLB **BGP** (eBGP→UDM, ECMP), VIP pool 10.10.201.70-90 — L2 mode removed 2026-05-31 (M18/M36, BGP-only) |
| Ingress | Traefik (10.10.201.70), wildcard cert `*.wind.etherport.net` via cert-manager + TLSStore default |
| Site-to-site VPN | K8s WireGuard pod primary (VRRP prio 150), `vpn-fallback` backup (prio 100), shared VIP 10.10.201.20 |
| AWS VPC | 10.10.100.0/22, peered with future spokes. The `*.wind.etherport.net` **ALB was decommissioned 2026-05-27** — public edge is now CF Tunnel + Access. |
| Cloudflare Tunnel | `cloudflared` routes public hostnames (`approve`, `cue.etherport.net`, …) through CF Access (Google SSO). **Internal** apps are gated by **Authentik** SSO (`auth.wind.etherport.net` — OIDC + a domain forward-auth middleware; H38). See CLAUDE.md §5. |
| Remote access | Tailscale (operator-managed K8s ingresses + subnet router) |

## DNS

| Zone | Authoritative | Notes |
|---|---|---|
| `etherport.net` public | Cloudflare (since 2026-05-25) | DNSSEC-signed, ~30 records. Manage via `infra/terraform/cloudflare/`. Route53 zone deleted. |
| `aws.etherport.net` private | Deleted 2026-05-27 | Never had real content; private zone removed with route53 module decom |
| `wind.etherport.net` internal | Technitium (in-cluster pair + dns-fallback VM + AWS edge-box replica) | MetalLB VIP 10.10.201.5 |
| 3 personal zones (grahamsmith / smithforsb / stopthecastle) | Cloudflare, DNSSEC enabled | Owned by [sparked-diamond/personal-web](https://github.com/sparked-diamond/personal-web) (split out 2026-05-27); SES domain identities + email forwarding recipients live there too. The forwarding Lambda itself stays in this repo. |
| DDNS writers | ddns-updater Lambda + cloudflare-ddns CronJob | ✅ **Migrated to the Cloudflare API** (2026-06). The CronJob writes `wind`/`wan1`/`wan2`/`sip` to the active WAN every minute. See `platform/kubernetes/cloudflare-ddns/README.md`. |

Module docs: `infra/terraform/cloudflare/README.md`. CF Free plan + ALB
decom + 5 Route53 zones deleted saves ~$27/mo vs pre-2026-05 baseline.

## Secrets

SOPS + age. The age **public** keys are in `.sops.yaml`. NB the primary **private**
key is held by 4 parties (mini disk, **devbox** disk, GH `SOPS_AGE_KEY`, Flux
`sops-age`) — factor that into rotation blast-radius (H33). To edit any `*.sops.yaml`:

```bash
sops <file>     # decrypts to your $EDITOR, re-encrypts on save
```

`*.sops.yaml.template` files are unencrypted scaffolds — copy to
`*.sops.yaml` and populate. Pre-commit hook `sops-encryption-check`
(`scripts/pre-commit/check-sops-encryption.sh`) rejects any plaintext
`*.sops.yaml`.

Setup: `docs/setup/secrets/SOPS-SETUP.md`. 1Password CLI bridges:
`docs/setup/secrets/1PASSWORD-CLI.md`.

## How to apply changes

### Kubernetes / Flux

Most changes — push to `main`, Flux reconciles within ~1min. To force:

```bash
kubectl annotate -n flux-system kustomization/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
# Check status with kubectl — there is NO flux CLI on the hosts (CLAUDE.md §3):
kubectl get kustomizations -n flux-system
kubectl get helmreleases -A
```

### Terraform — via workflow dispatch (default)

All TF projects run through GH Actions. **AWS** stacks run on
GitHub-hosted `ubuntu-latest` via GitHub→AWS **OIDC** (H29); the
**PVE/UniFi/Cloudflare/Google/Twilio** stacks run on the self-hosted
`lifecycle` runner with PVE/CF/UDM creds as **GH secrets**. Plan first,
then apply:

```bash
gh workflow run terraform-<project>.yml -f action=plan
gh workflow run terraform-<project>.yml -f action=apply
```

> **From the devbox there is no `gh` CLI** — dispatch workflows via the GitHub REST API
> with the M92 PAT (`github_dispatch_pat` in the SOPS ops bundle); snippets in
> [`infra/devbox/README.md`](infra/devbox/README.md). This applies to every `gh workflow run`
> example in this README.

Project → workflow map:

| Module | Workflow |
|---|---|
| `infra/terraform/proxmox/k8s-vms` | `terraform-proxmox-k8s-vms.yml` |
| `infra/terraform/proxmox/standalone-vms` | `terraform-proxmox-standalone-vms.yml` |
| `infra/terraform/proxmox/sdn` | `terraform-proxmox-sdn.yml` |
| `infra/terraform/proxmox/firewall` | `terraform-proxmox-firewall.yml` |
| `infra/terraform/unifi` | `terraform-unifi.yml` |
| `infra/terraform/cloudflare` | `terraform-cloudflare.yml` |
| `infra/terraform/google` | `terraform-google.yml` |
| `infra/terraform/aws/networking` | `terraform-networking.yml` |
| `infra/terraform/aws/compute` | `terraform-compute.yml` |
| `infra/terraform/aws/acm` | `terraform-acm.yml` |
| `infra/terraform/aws/ses` | `terraform-ses.yml` |
| `infra/terraform/aws/s3` | `terraform-s3.yml` |
| `infra/terraform/aws/email-forward` | `terraform-email-forward.yml` |
| `infra/terraform/aws/ddns-lambda` | `terraform-ddns-lambda.yml` |
| `infra/terraform/aws/dns-restrict-ip` | `terraform-dns-restrict-ip.yml` |
| `infra/terraform/aws/external-monitoring` | `terraform-external-monitoring.yml` |
| `infra/terraform/aws/homeassistant-alexa` | `terraform-homeassistant-alexa.yml` |
| `infra/terraform/aws/ai-advisor-iam` | `terraform-ai-advisor-iam.yml` |
| `infra/terraform/aws/cluster-irsa` | `terraform-cluster-irsa.yml` |
| `infra/terraform/aws/roles-anywhere` | `terraform-roles-anywhere.yml` |
| `infra/terraform/aws/twilio-webhook` | `terraform-twilio-webhook.yml` |
| `infra/terraform/aws/github-oidc` | *(bootstrap once with admin; then CI uses OIDC — H29)* |

Daily drift detection runs across these via `terraform-drift-detection.yml`
(see its matrix for the exact stack list) and opens a `tf-drift` GH issue if anything drifted. The
ansible-managed UDM firewall + switch ACLs are covered by the separate daily
`ansible-drift-detection.yml`.

### Ansible (Proxmox host, standalone VMs)

```bash
gh workflow run ansible-proxmox.yml        # PVE host (root over key)
gh workflow run ansible-vm-fleet.yml       # all standalone VMs
gh workflow run ansible-k8s-node-fixes.yml # K8s node OS-level fixes
```

The container image used by these workflows is built by
`ansible-runner-image.yml` (published to ghcr.io/sparked-diamond).

### Kubespray

Kubespray runs **from the devbox** (venv `~/.kubespray-venv`, ansible 11.13/core 2.18)
via the wrapper `infra/kubespray/kubespray.sh` — never raw `ansible-playbook`
(it restores `/opt/cni/bin` ownership afterwards; see
`docs/runbooks/cilium-cni-dir-owner.md`). Two devbox gotchas: export
`KUBESPRAY_SSH_KEY=~/.ssh/id_homelab_cert` (the wrapper default is the dead static
key — fleet SSH is cert-only, M76), and run long plays in a **detached tmux** (harness
background tasks get killed). Version-override facts: checksum overrides must be
**scalar** vars (e.g. `containerd_archive_checksum`), not the dict form — role
defaults beat inventory dicts. The CI `kubespray.yml` workflow_dispatch also exists:

```bash
gh workflow run kubespray.yml -f playbook=cluster   # full deploy
gh workflow run kubespray.yml -f playbook=scale     # add nodes
gh workflow run kubespray.yml -f playbook=upgrade-cluster
```

## Pre-commit hooks

```bash
brew install pre-commit
pre-commit install
pre-commit run --all-files
```

Configured (see `.pre-commit-config.yaml`):
- `terraform_fmt` + `terraform_tflint` — format + lint every `*.tf`
- `yamllint` — lenient YAML lint (config `.yamllint.yml`)
- `sops-encryption-check` — fail if any `*.sops.yaml` is plaintext
- `shellcheck` — lint shell scripts
- `gitleaks` — block accidental plaintext secrets (config `.gitleaks.toml`)

## CI gates (pull request + push to main)

- `flux-validate.yml` — `kustomize build` every overlay + `kubeconform` the
  rendered cluster (pre-merge safety the Flux layer otherwise lacks).
- `secret-scan.yml` — `gitleaks` server-side (the pre-commit hook only fires locally).
- `terraform-drift-detection.yml` — daily; opens a `tf-drift` GH issue on Terraform drift (AWS + cloudflare/unifi/proxmox/google/twilio).
- `ansible-drift-detection.yml` — daily; opens an `ansible-drift` issue if the UDM firewall/zones (`udm-firewall.yml`) or L3-switch ACLs (`usw-acls.yml`) drift from IaC.

## Task runner

`Taskfile.yml` (go-task) wraps the ops above: `task validate` (pre-commit +
kustomize-build + gitleaks), `task tf:plan MODULE=<x>`, `task flux:reconcile`,
`task secrets:edit FILE=<x>`, etc. `task --list` for all.

## Documentation map

- **Index**: [`docs/README.md`](docs/README.md) — full link tree
- **Architecture**: [`docs/architecture/`](docs/architecture/) — overview, network, firewall-zones, VPN (WG + TS), AWS
- **Runbooks**: [`docs/runbooks/`](docs/runbooks/) — day-to-day ops, AI advisor, cloudflare/cw2loki enable, DR, ceph migration
- **Setup**: [`docs/setup/`](docs/setup/) — first-time guides (kubespray, gitops, secrets)
- **Reference**: [`docs/reference/`](docs/reference/) — kubectl/kustomize cheatsheets, VLAN node setup
- **Planning**: [`docs/planning/outstanding-work.md`](docs/planning/outstanding-work.md) — source of truth for open H/M/L items; older snapshots in `archive/`
