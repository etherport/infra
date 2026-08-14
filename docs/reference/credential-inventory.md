# Credential & secret inventory

The **map** of every credential the `wind` homelab holds: what it is, where the
material lives, who consumes it, its rotation cadence, and its blast radius. This
is a reference for incident response and rotation planning — it does **not** hold
secret values (all live encrypted; see below).

- **How to rotate** any of these → [`../runbooks/secrets-rotation.md`](../runbooks/secrets-rotation.md).
- **SOPS + age mechanics** (encrypt/decrypt, recipients) → [`../setup/secrets/SOPS-SETUP.md`](../setup/secrets/SOPS-SETUP.md).
- **This doc is not Flux-reconciled** — keep it current by hand when you add/retire a credential.

> **One key rules them all.** The single SOPS **age recipient** decrypts *every*
> `*.sops.yaml` in the repo. Compromise of that private key = compromise of nearly
> everything below that is "stored: SOPS". Its four live holders + offline backup are
> the top of the blast-radius tree — see the rotation runbook's "Blast radius" section.

---

## 1. Master key — SOPS age

| Field | Value |
|---|---|
| **What** | age keypair; the private half decrypts all `*.sops.yaml` (5 `creation_rules` in `.sops.yaml`) |
| **Stored** | 4 holders: mini disk, devbox disk (`~/.config/sops/age/keys.txt`), GH secret `SOPS_AGE_KEY`, Flux secret `sops-age` (flux-system). **Offline backup** recipient in 1Password + paper safe (H33a). |
| **Consumers** | headless `sops -d` (mini/devbox), CI decrypt workflows, Flux reconcile |
| **Rotation** | routine hygiene + post-compromise — [secrets-rotation.md](../runbooks/secrets-rotation.md) |
| **Blast radius** | **total** — every SOPS secret. Rotation must re-key all 4 holders atomically. |

Everything marked **"SOPS"** below is encrypted to this key. The path column is the
`*.sops.yaml` file; decrypt with `sops -d <path>`.

## 2. AWS

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| `terraform-homelab` IAM access key | static IAM key | SOPS `homelab-ops.sops.yaml` (`aws_access_key_id/secret`) + GH secret | local-debug TF (`render-aws-credentials.sh`), shared with `[homelab]` profile | **rotate-only, NEVER delete** (H29 — shared). Not an M75 orphan. |
| `claude-admin` IAM key | static IAM key | **not in SOPS** — user pastes on request | ad-hoc cost/CloudWatch/IAM reads by the agent | least-priv (ce/cloudwatch/IAM read). Rotate if leaked. |
| IRSA roles ×5 (`wind-irsa-{velero,s3-sync,barman,cloudwatch-read,cue-media}`) | short-lived STS (AssumeRoleWithWebIdentity) | **no stored key** — projected SA token → STS | velero, s3-sync, CNPG barman, cloudwatch-to-loki, cue media | M75; **no static AWS keys in etcd**. Trust = the public OIDC issuer bucket. |
| GitHub→AWS OIDC role | short-lived STS (web-identity) | **no stored key** — GH OIDC token | CI TF stacks (AWS) | H29. |
| Roles Anywhere (mini) | short-lived STS from a step-ca cert | cert on mini | mini-side TF plan/debug | M71 (scoped: ReadOnly + tfstate RW, deny data/secret reads). |
| 4 orphaned dedicated IAM keys | static (Active, in git history) | git history + AWS | none (superseded by IRSA) | ⏳ **deactivate/remove** — the only M75 follow-up. |
| SES SMTP credentials | static (protocol) | SOPS (alertmanager/app secrets) | alertmanager, app mailers | **stays static** — SMTP has no short-lived form. |

## 3. SSH (fleet = cert-only, M76)

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| step-ca **user CA** | CA keypair | step-ca VM 1006 (`~/.step`) | signs 13h devbox certs + ≤1h CI certs; trusted via `TrustedUserCAKeys` on all 15 hosts | the trust root for fleet SSH. Break-glass if down: PVE console + IPMI. |
| step-ca **host CA** | CA keypair | step-ca VM 1006 | `HostCertificate` on 13 Servers-VLAN hosts (kills known_hosts TOFU) | — |
| Devbox SSH user cert | 13h cert (ECDSA) | devbox `~/.ssh/id_homelab_cert` | agent + interactive SSH to fleet | auto-renewed every 6h (`step-ssh-renew.timer`); staleness alerted (M133). |
| `automation@homelab` static key | static SSH key | SOPS `homelab-ops.sops.yaml` (`automation_ssh_private_key`) | **bootstrap seed ONLY** — cloud-init/packer + scoped appliance keys; **rejected by the running fleet** | survives as the rebuild seed (M76); do not re-add to `authorized_keys`. |
| `advisor-ssh-key` | static SSH key | SOPS `auto-remediation/advisor-ssh-key.sops.yaml` | ai-advisor remediation actions | hand-edited standalone. |

## 4. GitHub

> **2026-08 org migration + GitHub App.** The repos moved from the `sparked-diamond`
> USER to the **`etherport` ORG**. User-scoped PATs cannot see org repos at all, so the
> PAT-based credentials were replaced by a **GitHub App** minting 1h installation tokens.
> The App private key does **not expire** — this ended the PAT rotation treadmill.

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| **`etherport-automation` App** (id `4539969`, installation `152499241`) | App private key (PEM) → 1h installation tokens | SOPS `homelab-ops.sops.yaml` (`github_app_id`, `github_app_installation_id`, `github_app_private_key`); k8s `flux-system/flux-github-app`, `backups/github-app-creds` | **Flux git** (HTTPS + `provider: github`), **repo-mirror backup**, **devbox dispatch** (`scripts/gh-app-token.sh`) | Key does NOT expire — rotate on compromise only. Perms: contents:write, actions:write, metadata:read, packages:read. Mint scoped per use (`--permissions`). |
| **`cue-ci-monitor` App** | App private key | cue repo's own secret store (infra holds no copy) | cue CI monitoring + `cue-certs` clone for fastlane match | Scoped Actions:read + Contents:read on `cue` + `cue-certs` ONLY — deliberately not the org-wide App. |
| GHCR pull token | classic PAT, `read:packages` ONLY | SOPS `ghcr_pull_token`; k8s `ghcr-etherport` (backups/cloudflare-ddns/cloudwatch-to-loki), `cue/ghcr-cue`, `flux-system/cue-ghcr` | pulling private `ghcr.io/etherport/*` images | ⚠️ **EXPIRES 2026-08-31** and EVERY pull secret is the SAME token → on expiry all private pulls fail cluster-wide. **Cannot move to the App: GHCR rejects App installation tokens (403, tested).** Classic PATs are always user-owned. Monitored via `credential_expiry_timestamp_seconds{credential="ghcr_pull_token"}` + the <30d alert. |
| ~~`github_dispatch_pat`~~ | RETIRED 2026-08-13 | — | — | Replaced by the App (it 404'd on org repos). Delete on GitHub if still listed. |
| ~~`github-mirror-token`~~ | RETIRED 2026-08-13 | — | — | Replaced by the App. It could only see 1 of 6 org repos — a silently near-empty backup. |
| ~~Flux SSH deploy keys~~ | RETIRED 2026-08-13 | — | — | Deploy keys are disabled org-wide; Flux uses the App over HTTPS. |
| GHCR pull secrets for the 4 utility images | dockerconfigjson | k8s (see above) | aws-s3-sync, cloudflare-ddns, cloudwatch-to-loki | ⏳ Become **unnecessary** once those packages are flipped back to **public** (they were public pre-migration). `cue` stays private, so the token is still required regardless. |

## 5. step-ca provisioner

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| `jwk_password` | JWK provisioner password | SOPS `step-ca.sops.yaml` | devbox/CI mint certs headlessly (`headless` JWK provisioner) | compromise = attacker can mint fleet SSH certs → high blast radius. |
| step-ca root/intermediate keys | CA keys | step-ca VM 1006 | the CA itself | — |

## 6. Appliances (UDM / Protect / UNAS / IPMI)

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| `udm_api_key` | UniFi Network API key | SOPS `homelab-ops.sops.yaml` | udm-firewall.yml, TF unifi provider (`X-API-KEY`) | rapid logins trip the UDM rate-limiter. |
| `udm_tfadmin_*` | UDM admin login | SOPS `homelab-ops.sops.yaml` | fallback UDM auth | — |
| `udm_ssh_user/password` | UDM/Protect SSH | SOPS `homelab-ops.sops.yaml` + `unifi-backup/01-secret-ssh.sops.yaml` | unifi-backup CronJob, Protect SSH (`Windprotect`) | — |
| `protect-tf` key | Protect integration API | SOPS | Protect reads | **read-only** — Alarm Manager automations are UI-only. |
| IPMI (`10.10.200.21`) | BMC login | SOPS / documented | break-glass console, ipmi_exporter | break-glass path if step-ca down. |
| UNAS (`10.10.209.10`) | login | SOPS | NAS admin | — |

## 7. Cloudflare

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| CF API token | scoped API token | SOPS `homelab-ops.sops.yaml` + `cert-manager-issuer/` + `cloudflare-ddns/` | cert-manager DNS-01, cloudflare-ddns, TF cloudflare | — |
| Tunnel token | cloudflared tunnel creds | SOPS `cloudflared/01-tunnel-token.sops.yaml` | cloudflared (edge tunnel) | compromise = edge ingress impersonation. |

## 8. SSO / Authentik + app OIDC

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| Authentik secret key + bootstrap | app secret | SOPS `authentik/30-authentik-secret.sops.yaml` | Authentik server/worker | `akadmin` = break-glass admin (password in UI, never in a blueprint). |
| Grafana OIDC client secret | OIDC secret | SOPS `monitoring/grafana-oidc-secret.sops.yaml` | Grafana ↔ Authentik | — |
| Open WebUI / wiki.js OIDC | OIDC secret | SOPS `ollama/09-open-webui-oidc.sops.yaml`, wikijs | OIDC apps | — |
| CNPG `authentik` DB role | DB password | SOPS `cnpg/07-authentik-role.sops.yaml` | Authentik → shared HA postgres | — |

## 9. Databases

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| CNPG superuser/app creds | DB passwords | SOPS `cnpg/02-credentials.sops.yaml` | CNPG clusters (HA + cue-db) | — |
| Barman S3 creds | (now IRSA) | IRSA — no static key | CNPG WAL/base backups | M75. |
| wiki.js DB | DB password | SOPS `wikijs/02-db-secret.sops.yaml` | wiki.js | — |

## 10. Monitoring / alerting

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| Grafana admin | password | SOPS `monitoring/grafana-admin-secret.sops.yaml` | Grafana break-glass (SSO is primary) | — |
| Alertmanager secret | SMTP/webhook creds | SOPS `monitoring/alertmanager-secret.sops.yaml` | alert email routing | — |
| Blackbox config secret | probe creds | SOPS `blackbox-exporter/01-config-secret.sops.yaml` | appliance HTTPS probes | — |

## 11. Application / external APIs

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| Anthropic API key | API key | SOPS `auto-remediation/anthropic-api-key.sops.yaml` | ai-advisor (Claude calls) | — |
| Twilio (`account_sid`, `api_key`, `api_secret`) | API creds | SOPS `homelab-ops.sops.yaml` | asterisk-sbc / Twilio Talk | — |
| Google (Places / Alexa) | API key / TF secret | SOPS `terraform/aws/homeassistant-alexa/secrets.sops.yaml` + cue-api | cue Find-food, HA Alexa | — |
| `icloud_app_password` | app-specific password | SOPS `homelab-ops.sops.yaml` | cairn iCloud backup (mini) | — |
| Approval HMAC secrets | HMAC key | SOPS `auto-remediation/approval-hmac-secret.sops.yaml`, `backups/approval-server/01-hmac-secret.sops.yaml` | signed approve-button links (advisor + backups) | — |
| Claude OAuth token | OAuth creds | devbox `~/.claude/.credentials.json` (**not** SOPS) | Claude Code dev sessions | transplanted from mini Keychain (headless OAuth broken, GH #47152). |

## 12. Network control-plane

| Credential | Type | Stored | Consumers | Rotation / notes |
|---|---|---|---|---|
| WireGuard server/client keys | WG keypairs | SOPS `platform/wireguard/{servers,clients}/*.sops.yaml` + `wireguard/01-secrets.sops.yaml` | vpn-aws, vpn-fallback, K8s WG pod, clients | — |
| MetalLB↔UDM BGP MD5 | TCP-MD5 password | SOPS `metallb/02-bgp-md5-secret.sops.yaml` | MetalLB FRR ↔ UDM peer | mismatch drops ALL BGP → VIP/ingress/DNS withdrawal (L24). |
| Ceph client key | cephx key | SOPS `inventory/wind/group_vars/all/ceph-k8s-secret.sops.yaml` | K8s ceph-csi → external Ceph | — |
| Technitium admin | login | SOPS `technitium/05-secret.sops.yaml` | DNS admin | — |
| etcd backup creds | (host-level) | SOPS `etcd-backup.sops.yaml` | CP systemd etcd snapshot timer | **not** an IRSA target (host-level, M71). |

---

## Management classes (for rotation)

Per the rotation runbook, downstream secrets split into two classes:
- **1P-managed (synced):** rendered by `scripts/sync-secrets.py` from
  `homelab-ops.manifest.yaml` → `homelab-ops.sops.yaml`. Covers AWS(tf), UDM,
  Cloudflare, Twilio, the automation SSH key, github_dispatch_pat, icloud.
- **Hand-edited standalone SOPS files:** rotated with `sops <file>` directly —
  Anthropic key, SES SMTP, Ceph, WireGuard, approval-HMAC, advisor-ssh-key,
  CNPG/barman, grafana-admin, OIDC client secrets.

## Non-SOPS credentials (the exceptions)

These are **not** protected by the age key — track them separately:
- **claude-admin** IAM key — pasted on demand, never stored in-repo.
- **Claude OAuth token** — devbox `~/.claude/.credentials.json`.
- **step-ca CA keys** — live on VM 1006, never leave it.
- **Offline SOPS backup key** — 1Password + paper safe.
- **IRSA / OIDC / Roles Anywhere** — short-lived, minted on demand, nothing at rest.
