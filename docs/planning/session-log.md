# Session Log — narrative history

Append-only, **newest first**. One entry per substantive working session: what was
done, **why** (decisions/rationale that the code alone won't tell you), the state at
end, and explicit next steps. This is the artifact for resuming work if the chat
history is lost or you're picking up on a different machine.

**Maintenance:** add an entry at the end of every substantive session (see
[`../../CLAUDE.md`](../../CLAUDE.md) §6). For the structured, ID'd to-do status, see
[`outstanding-work.md`](outstanding-work.md). Pre-2026-06-14 session history lives in
that tracker's "Recently completed" blocks and the dated planning docs
(`gcp-oidc-wif-l21.md`, `cloudflare-provider-v5-migration.md`, etc.).

---

## 2026-06-24 (cont. 11) — M82: Terraform → CI-only, devbox drops standing AWS/PVE creds

Owner chose **CI-only** for M82 (over keep-on-devbox / re-home). Most of the path was
already there (M92 dispatch PAT done; ~every TF stack has a workflow). Executed:
- **Added `terraform-proxmox-firewall.yml`** — the one TF stack lacking CI (the H37 host
  firewall). Modeled on terraform-proxmox-sdn (self-hosted `lifecycle` runner,
  `PROXMOX_TOKEN_*` secrets, S3/OIDC backend) but **TF 1.15.5** — the state was written by
  1.15.5 (devbox), and 1.14.3 (what the sibling proxmox workflows pin) would refuse it.
  Pushing it auto-triggers a plan → validates runner/secrets/state (check Actions UI).
- **Removed the standing `~/.aws/[homelab]` key from the devbox.** The AWS key remains only
  SOPS-encrypted (verified still in the bundle) + as GH secrets; no plaintext at rest on the
  devbox disk. `~/.aws/config` kept (no secret). On-demand re-render via
  `scripts/render-aws-credentials.sh` for rare local debug (throwaway, not standing).
- **CLAUDE.md §4 updated** to the new model: devbox = Actions:write PAT (M92, dispatch CI) +
  SOPS age key (headless `sops -d`), **no standing AWS/PVE creds**; TF via CI.
- **Latent finding:** sibling proxmox workflows pin TF **1.14.3** but the firewall state is
  1.15.5 — if the devbox ever applied the other proxmox stacks at 1.15.5, their CI would
  break on the version skew. Worth aligning the proxmox workflows to 1.15.5 (follow-up).

**Verify (owner):** firewall workflow plan run green + `PROXMOX_TOKEN_*` GH secrets present.
**Next ZT:** M71 — the devbox is now clean; remaining standing keys are on the **mini**
(`[homelab]` + `[claude-admin]` PowerUser) + the never-rotated keys — mini/admin actions.

---

## 2026-06-24 (cont. 10) — UDM/network hardening cleanup (VPN-zone tighten + audit)

Network-hardening tidy-up pass on the UDM. **Done + verified:**
- **M42 — VPN-zone allows tightened** (`udm-firewall.yml`): `Vpn → Trusted (all)` +
  `Vpn → Management (all)` → `(admin)` = **TCP on a new `Vpn-Admin-Ports` group**
  (22/53/80/443/6443/8006), logging on. Keeps the UDM backup WireGuard tunnel + `Vpn`
  zone (owner wants it as break-glass for cluster/PVE VPN loss + future tunnels e.g.
  Teleport) but a connected client no longer gets full LAN reach. Applied live from the
  devbox (the playbook is **create-only** per H34, so: real apply created the group + 2
  `(admin)` policies additively, then **API-deleted** the 2 old `(all)` policies — their
  auto `(Return)` twins cascaded). Verified: only `(admin)` remain. Empty zone (0 VPN
  clients) → no live impact. Resolves firewall-zones anomaly #3.

**Audited / confirmed (owner asks):**
- **Default network (199) is unused** — UDM API shows **0 of 102 active clients** on
  10.10.199.x. It stays (it's the native transit + `.1` default route). NB you can't fix
  the "device on an unused port lands on trusted-transit 199" risk by tightening the
  `Internal` zone — the switch-routed VLANs (201/202/209/210) are zoneless and **transit
  through `Internal`**, so `Internal→Trusted (all)` carries legit clients→servers traffic.
  The fix is at the **switch-port level**.
- **~33 unused/down switch ports** fleet-wide; **no "Disabled" port profile exists**, and
  several profiles (Cameras/Phones/APs/UniFi-Devices) + the fallback are native to
  Default/199. → UI action: create a Disabled profile, apply to unused ports.

**Decisions (owner):** Security/205 isolation+DNS → **FIX** (UI: disable Network Isolation,
set DHCP DNS .5/.6); LTE WAN → **keep**; VPN zone → **keep + tighten** (done).

**Recommendation captured (task #18) — physically-exposed switches** (Driveway, Access Road,
Outdoor Junction, Chapel, ua-gate): disable unused ports + **per-port VLAN minimization**
(camera→Security/205, AP→its SSID VLAN, gate→Access VLAN, so a hijacked port lands in an
already-isolated zone) + **802.1X/MAB** via RADIUS (only the "Default" placeholder profile
exists today). MAC filtering alone is spoofable — VLAN confinement + zone firewall is the
real control.

**M47 — DONE 2026-06-24 (auth-swap):** `udm-firewall.yml` now prefers `X-API-Key`
(`udm_api_key` from the SOPS bundle / `UDM_API_KEY` env) and falls back to the
username/password login when no key — verified both paths via `--check` (failed=0).
`ansible-unifi.yml` passes `UDM_API_KEY` (empty → fallback). Follow-up: add the
`UDM_API_KEY` GH secret, then drop the login fallback. Verified `X-API-Key` works on the
legacy + v2 endpoints (200; bad key → 401).

**Still open (UI / queued):** Security/205 fix (UI — **M104**), unused-ports → Disabled incl.
the outdoor switches (UI — **M103** / task #18), **L24** BGP session auth (UI/FRR).

---

## 2026-06-24 (cont. 9) — H30 supply-chain CLOSED (image digest-pinning, staged)

Finished H30. Found two of the "deferred" items already done (the 3 TF workflows use the
checksum-verified `setup-sops` action; all 111 Actions SHA-pinned via PR #62). The real
remainder was **image digest-pinning**: added `digestReflectionPolicy: Always` + `interval`
to **all 13 `ImagePolicy` objects** so Flux image-automation rewrites manifests to
`tag@sha256:…` (immutable supply chain).

**Staged rollout (owner chose "non-critical first")** — given it rolls the whole Flux fleet:
1. **Canary** `blackbox-exporter` (`206417b`): validated the full mechanism end-to-end —
   ImagePolicy resolves the digest (in this Flux build the resolved ref is in the Ready
   *condition message*, not `.status.latestImage`, which reads empty) → automation commits
   `prom/blackbox-exporter:v0.28.0@sha256:…` → Flux applies → pod rolls 1/1 clean.
2. **Wave 1** (non-critical): python-alpine/-slim, busybox, velero-plugin-aws, rclone,
   open-webui, ollama, wikijs — all digest-pinned + rolled healthy (auto-remediation, velero,
   open-webui, ollama, wiki-js).
3. **Wave 2** (sensitive): technitium DNS, cloudflared, home-assistant, plex. technitium STS
   + cloudflared are **2-replica** → rolled one-at-a-time → **DNS stayed up** (verified
   `getent grafana.wind.etherport.net → 10.10.201.70` from dns-ns + cue-ns pods) and the
   tunnel stayed up. HA/Plex took a brief single-pod restart.

**Result:** all 13 upstream images digest-pinned, fleet healthy, nothing broke. **In-house
images (aws-s3-sync etc.) deliberately left on `:main`** (we build them; CI rebuild on push +
imagePullPolicy:Always; the tag-mutation threat barely applies) and **cue-api on `:latest`**
(dev) — bringing them under Flux digest is optional future work, not required for H30.
**Gotcha for future:** `.status.latestImage` is empty in this image-reflector build — check
the ImagePolicy's Ready **condition message** for the resolved tag+digest.

---

## 2026-06-24 (cont. 8) — backup verification false-negative fixed (special-char keys)

**Symptom:** overnight the `backups` share's s3-sync ran FAILED — `homelab_backup_last_run_success{share="backups"}=0`, **9 of 20,813 files "failed verification"** (the run that mirrored yesterday's 20,813-file mini iCloud push incl. 19,951 Messages attachments). The `S3SyncFailed` alert fired; the **AI advisor handled it correctly** — diagnosed once then `Cooldown active … skipping action` (H39 dedup working, no email flood).

**Root cause (NOT data loss):** pulled the consolidated report (`s3://logs.archive…/reports/backups/20260624T080019Z/report.json`) — the 9 were `checksumMismatches:0`, `errorCode:HeadObjectFailed`, message *"…bucket name must match the regex…"*. That's botocore's **--bucket** validation: the GNU-parallel verify path used unquoted column substitution (`parallel --colsep '\t' verify-one.sh {1} {2} …`), which **mangled the args for keys with spaces+special/multibyte chars** (curly apostrophe U+2019, `!`, parens, odd spacing) → a bogus `--bucket` → HeadObjectFailed. The 20,804 plain keys passed; only the 9 awkward ones failed. **All 9 objects confirmed present in S3** (head-object OK with proper quoting) → pure verification false-negative.

**Fix (`a700b3f`):** pass the whole tab-delimited `bucket<TAB>key` line as ONE opaque arg (`{}` in parallel; `"$REC"` in the bash fallback) and split byte-exact with `IFS=$'\t' read` inside `verify-one.sh` — robust to any key. **Validated against all 9 real keys → 9/9 now pass.** The image rebuilds on push (`aws-s3-sync-image.yml`, path-filtered) + `imagePullPolicy: Always`, so the next run uses it. The alert clears on the next successful run (a no-change re-run has 0 uploads → verification skipped → success; the fix matters next time a batch of special-char files uploads).

---

## 2026-06-23 (cont. 5) — mini observability restored (VIP fix verified) + size metric + mini_health heartbeat

**VIP fix verified from the mini.** Infra restored the mini→Traefik-VIP route (Cilium `traefik-tier` was allowing the LB *service* ports :80/:443 from world but enforces on the DNAT'd *container* ports :8000/:8443 — commit 1a98eee). From the mini: `nc 10.10.201.70:443` connects, end-to-end pushgateway POST works (PUSH_OK), Alloy→Loki clean since restart (was timing out until 23:07Z). Re-pushed all backup metrics: messages/notes/safari/drive/photos green+fresh. **contacts/calendars rc=1 = transient iCloud DAV throttle** from my dozens of debug runs (manual `discover` succeeds; data safe, master intact) — left to self-heal on the 21:00 nightly; do NOT keep re-running (worsens the throttle).

**Dashboard asks (owner): item count + size-on-disk per category, both dashboards.** Item count already exists (`<job>_items` / `photos_export_photos_total`). Added **size**: `<job>_bytes` (+ `photos_export_bytes`) via new `nas_du_bytes` helper (du of each NAS dest, bounded timeout + skip-on-fail so a slow du never zeroes the panel), emitted opt-in via `BACKUP_BYTES`/`PHOTOS_BYTES`; wired into all 8 categories. `2267fc8`.

**Agent-health metric (owner).** New `mini-health.sh` + `net.wind.mini-health` (every 15 min, RunAtLoad) pushes `mini_health_*`: `mini_health_up` (rollup), `mini_health_check{check="agents_loaded|nas_readable|nsmb_applied"}`, `agents_loaded`/`agents_expected` (6), `disk_free_bytes`, and `mini_health_last_check_timestamp_seconds` (heartbeat). The heartbeat is the dead-man's-switch — if it stops arriving the mini is down or can't reach the VIP (would've caught today's outage). Cheap + FDA-free (launchctl/mount/df/rsync-stat). Verified push: up=1, agents 6/6, nas/nsmb ok, 21G free. **Infra-agent handoff (prompt given to owner):** add item-count + size panels per category to BOTH dashboards; surface `mini_health` in the 06:00 service-status-report email + alert on `mini_health_up==0` and heartbeat-absence.

---

## 2026-06-24 (cont. 7) — Control-plane OS patch (cp1/cp2/cp3) — completes M101 node patching

Patched the 3 control planes with `infra/ansible/playbooks/k8s-node-patch.yml`, finishing
the node-patch rollout (workers/GPU were done 06-23). **Key nuance — there is NO HA API
VIP:** `controlPlaneEndpoint` is the single cp1 `10.10.201.50:6443`, workers reach the API
via their local kubespray `nginx-proxy` (→ all CPs), and external clients (my kubeconfig,
the mini) point straight at cp1. etcd runs as a **systemd service** (not static pods; certs
`/etc/ssl/etcd/ssl/`, `etcdctl` env in `/etc/etcd.env`), 3 members.

**Procedure (safe path without a VIP):** the playbook's kubectl steps are all
`delegate_to: localhost` (run on the devbox), so I patched each CP with `-l <cp> -e
kubeconfig_path=<temp kubeconfig pointed at a DIFFERENT healthy CP>`. Order **cp2 → cp3 →
cp1**, leaving cp1 (etcd leader + endpoint) for last; cp2/cp3 patched via cp1, cp1 via cp2.
Built temp kubeconfigs by `sed`-swapping the server URL (verified each CP's apiserver cert
SANs cover all 3 IPs — `/healthz` ok on each). Pre-flight: etcd 3/3 healthy, CP taints
present (clean drains), only HA/reschedulable pods evictable (cilium-operator/coredns/etc.).
Between each CP I re-verified **etcd endpoint health + matched raft index** (quorum holds
with 1 CP down; serial:1 is mandatory for a 3-node CP). On cp1's reboot etcd cleanly
re-elected the leader cp1→cp2 (term 68→69).

**Result:** all `failed=0`, all CPs Ready on uniform kernel `6.8.0-124`, etcd 3/3 in sync,
0 unhealthy pods, original cp1 kubeconfig works again, reboot-required cleared on all three.
Patches were userspace (apparmor/snapd/cloud-init/libxml2/qemu-guest-agent) but still
triggered a (clean) reboot each. Temp kubeconfigs `shred`-deleted after. M101 node-patching
DONE. **Future CP patches: reuse the per-CP `kubeconfig_path` trick until/unless an HA
apiserver VIP is added.**

**Also closed the last M101 residual** (`bb2c32c`): added the devbox `10.10.201.45:9100` to
the `external-nodes` Prometheus scrape job (`01-external-scrape-config.yaml`, instance=`devbox`).
Verified `up{instance="devbox"}=1`, no errors. **M101 fully DONE** — only deliberate residual
is third-party repo (1Password/NodeSource) auto-update.

---

## 2026-06-24 (cont. 6) — Cue public access + Web Push; VIP-outage preventive alert; doc review

**Cue public internet access** (`33b368a` `93f76d4` `6e42876`, applied via CI earlier today):
`cue.etherport.net` now served through the CF Tunnel with **per-path** Zero-Trust Access —
the app behind **Google SSO** (allow-list `cue_tester_emails`, default `grahamsm@gmail.com`),
`/health` **bypass** (no auth, for uptime checks), and `/ingest/healthkit` behind a
**service token** (`cloudflare_zero_trust_access_service_token.cue_healthkit`) for the
HealthKit ingestor. cue-api verifies the CF Access JWT itself via `CUE_CF_ACCESS_TEAM_DOMAIN`
(`etherport.cloudflareaccess.com`) + `CUE_CF_ACCESS_AUD` (the app AUD). TF in
`infra/terraform/cloudflare/cue-access.tf`; the cue ingress regex was set to null (serve the
whole app). **To add a tester:** append their email to `cue_tester_emails` in
`cloudflare/variables.tf` + `terraform apply` (or switch the policy to a Google Group for
higher churn). Applied from CI, not the devbox (devbox TF hit empty-IDP + http refresh errors).

**Cue Web Push enabled** (`49953f9`): added `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`/`VAPID_SUBJECT`
(= `mailto:grahamsm@gmail.com`) to the `cue-app` SOPS secret (values from
`/home/ubuntu/code/cue/vapid.private.json`, never echoed; secret stays encrypted) + set
`CUE_WEB_PUSH=true` inline in the deployment (`CUE_PROACTIVE_CHECKINS` already on). Push
egress to browser push services (`:443`) is already covered by cue-tier's `world:443` egress —
no netpol change. cue-api rolled 1/1, 0 restarts, all 4 env vars populated.

**VIP-outage PREVENTIVE GUARD** (`4d57c3e`) — the "doesn't repeat" half of cont.5. Added a
third loki-ruler rule **`CiliumTraefikIngressDrop`** (critical) in
`06-loki-rules-cilium-audit.yaml`: fires on ANY `DROPPED` flow to the traefik tier on a
PUBLIC entrypoint container port (`:8000`/`:8443`/`:8088`). Those ports MUST accept `world`
by design, so a drop there is *always* a policy bug — which is why this rule deliberately
does NOT exclude `world`/empty-`src_ns` (the existing `CiliumNetpolDropFlow` filters
`src_ns!=""` to drop scan noise, and that exact filter is what hid the 06-23 outage for
~16h — the DROPPED flows were in Loki the whole time, just unalerted). Now a future
external→VIP netpol break pages in ~10m. (Couldn't query Loki to replay the historical
drops — the distroless loki image has no shell/wget — but the rule reuses the identical JSON
fields as the working `CiliumNetpolDropFlow`, and cilium-monitor during the outage confirmed
`world→traefik …→:8443`.) Live: cm has 3 rules, Flux `4d57c3e`.

**Doc review pass:** confirmed today's items are captured — Authentik SSO (H38, cont.3 +
CLAUDE.md §5), M80 iCloud backups (cont.4), the VIP outage (cont.5), and now cue + the
guard. CLAUDE.md §5 DROP-alerting note updated (3 rules; the remaining `world`→non-traefik
gap is explicit). Mini backup dashboard/alerts confirmed **already generic** (templated
`cat` repeat + `.+_backup_*` regex) — new categories (messages/notes/safari/icloud_drive)
auto-appear once the mini re-pushes (nightly cron, now that the VIP path is fixed); no change
needed.

**State:** all of today's work shipped + documented. Open follow-ups: mini metric pushes
resume on tonight's cron (verify pushgateway freshness then); control-plane node patch
(cp1/2/3) still pending; cue-api still on `:latest` (intentional during dev, M64).

---

## 2026-06-23 (cont. 5) — mini→VIP outage ROOT-CAUSED + FIXED (traefik netpol: service vs container ports)

**Resolved the cont.4 mini→Traefik-VIP outage. Root cause: the `traefik-tier`
CiliumNetworkPolicy allowed the LoadBalancer SERVICE ports from `world`, but Cilium
evaluates ingress at the destination pod on the CONTAINER (target) port that kube-proxy
DNATs to *before* policy is applied.** Mapping: svc `:80 web → :8000`, `:443 websecure
→ :8443/TCP`, `:443 http3 → :8443/UDP`, `:8088 webhook → :8088` (same number). The CNP's
`fromEntities:[all]` block listed `80/443/8088`; `:8443` was allowed only from `cluster`.
So in-cluster→VIP worked (cluster identity) while **every `world`→VIP flow was dropped**
(`drop (Policy denied) identity world→traefik … →:8443 tcp SYN`). `:8088` was the lone
survivor (same port number, no remap) — which is why webhooks + photos alerts kept working
and confused the triage. Became a **hard outage when the traefik tier flipped audit→enforce
(06-23 tightening)** — ~16h of no mini metric pushes / log shipping. **Not reboot-related**
(confirmed the operator's hypothesis).

**Fix** (`1a98eee`): ingress `fromEntities:[all]` now allows the **container** ports
`8000/TCP, 8443/TCP, 8443/UDP, 8088/TCP`; `:8080` (api/dashboard/mgmt) stays cluster-only.
Applied + Flux-reconciled (no drift). **Verified** via a forced-route repro from the devbox
(`ip route add 10.10.201.70/32 via 10.10.201.1`, which makes the same-subnet devbox take the
routed `world` path that the mini uses): VIP `:443 → 404`, `:80 → 301` (Traefik responding;
was `000`/timeout). Mini pushes resume on its next cron cycle.

**Diagnostic path that nailed it** (after a long hunt down BGP/kube-proxy/iptables/host-fw —
all red herrings): tcpdump on the worker showed the SYN *arriving* on eth0; the
`iptables -t nat KUBE-SERVICES` packet counter for the VIP *incremented* (DNAT fires) — so it
was **post-DNAT**. `cilium-dbg monitor --type drop` (with the forced route, and NOT grepping
for `201.70` — post-DNAT the dst is the *pod* IP) surfaced the `Policy denied … →:8443` drop.
**Lesson: when chasing a MetalLB-VIP datapath drop, monitor for the POD IP + container port,
not the VIP.** The earlier "toggle test" (de-label traefik ns) was a false-negative — those
re-tests went via the devbox's same-subnet ARP path without the forced route, so the packet
died before reaching the policy.

**Caveat exposed:** the traefik tier's "0 AUDIT flows → enforce" validation (cont.3/H3) was
**incomplete** — the `world`→VIP→`:8443` ingress path was never actually exercised through the
VIP during the audit window (only egress device routes + in-cluster ingress were). Container-
vs-service-port is now a CLAUDE.md invariant + documented in the netpol README/runbook.

---

## 2026-06-23 (cont. 4) — M80 Messages backup COMPLETE + Notes/Safari/Drive added; mini→VIP observability outage

**Messages backup DONE** (`messages-backup.sh`, 20:00). chat.db: 319,679 msgs, integrity ok; attachments: **19,951 files / ~48 GB**. The attachments first-copy needed the **parallel sharded** mirror (256 hex top-dirs × 6-way `xargs -P` rsync) — serial was ~1 file/s (~5h); parallel ~6× (finished in ~1h13m over 2 attempts, attempt-1 timed out at 40min, attempt-2 resumed). Two bugs fixed en route: (a) `mini_run_timeout`-wrapped `xargs` lost stdin → empty input → false rc=0 "complete" copying nothing (fix: background `xargs` with the `<SHARDS` redirect DIRECTLY on it + own watchdog); (b) the FDA/launchd saga from cont.2. **Metrics now split**: `messages_backup` (DB/msg count) + `messages_attachments_backup` (file count) report independently.

**Notes + Safari + iCloud Drive added** (`icloud-files-backup.sh` + `net.wind.icloud-files.plist`, 19:30): Notes (whole group container, NoteStore.sqlite integrity-checked read-only before mirror — **414 notes / 397 MB**), Safari `Bookmarks.plist` (464 KB), iCloud Drive (CloudDocs — **only 2 local files, 0 stubs**; owner doesn't use it for production, confirmed). Each a guarded rsync mirror (`--max-delete`, refuse-missing) with its own metric (`notes_backup`/`safari_backup`/`icloud_drive_backup`). Reminders confirmed **already covered** (CalDAV VTODO in the Calendars sync). **iCloud backup coverage is now complete** for everything the owner uses.

**⚠️ mini→Traefik-VIP observability OUTAGE (open, infra-agent handoff).** The mini (10.10.202.101) can't TCP-reach the Traefik VIP `10.10.201.70:443` (timeout) since today's firewall/netpol/H38 cleanup, so ALL mini metric pushes (Pushgateway) + log shipping (Loki/Alloy) fail — both route through that VIP. **Backups are UNAFFECTED** (they go to the NAS `sequoia:445`, reachable). Pushgateway/Loki are healthy (in-cluster pushers reach them via ClusterIP); only the external mini→VIP route is broken. Likely the UDM zone firewall (202→201/VIP allow dropped), MetalLB↔UDM BGP, or H38 Traefik forward-auth on the pushgateway/loki routes. Full infra-agent prompt (route fix + dashboard/alert wiring for the 5 new metric series) handed to the owner this session. Until fixed, mini `*_last_success` reads stale — expected backlog, not a backup failure. Commits `510db28` `31b06f3` `06af775` `4a72751` `59d1178`.

---

## 2026-06-23 (cont. 3) — Authentik SSO pass COMPLETE + login branding; S3 approval-flow; M101 VM patching

Closed out the Authentik SSO pass (H38), plus a cluster of smaller items.

**SSO — native OIDC:** Grafana (prior), **Open WebUI** (`chat`; env-driven, fully GitOps), **wiki.js** (`wiki`; Authentik blueprint with a **regex** redirect because wiki.js mints the callback path when its OIDC strategy is created — the wiki *side* is DB/admin-UI config, entered by hand). Blueprints in `40-blueprints.yaml`, client secrets in SOPS + shared via `!Env` to the providers.

**SSO — forward-auth (domain-level):** one proxy provider `forward-auth` (mode `forward_domain`, cookie `wind.etherport.net`) on the **embedded outpost** + a single Traefik `authentik-forward-auth@authentik` middleware (cross-namespace; `allowCrossNamespace=true`). Wired to: Proxmox (canary, verified), IPMI, PDU×2, UPS×2, Technitium DNS admin, Traefik dashboard (**was unauthenticated**). Domain-level means device UIs only need the middleware — the handshake redirects to `auth.wind` and the `*.wind` cookie carries across; no per-host outpost route needed.

**Deliberately NOT forward-authed (decisions):** **HA** + **Plex** keep their own auth — fronting HA would break the mobile app, API/webhook clients (Protect webhooks use the separate `:8088` entrypoint, so those are fine), and external CF-tunnel logins (forward-auth redirects to internal-only `auth.wind`). **loki/pushgateway/ollama** are machine APIs (the off-cluster mini pushes logs+metrics to `loki.wind`/`pushgateway.wind`; `ollama.wind` is a documented API base URL) — forward-auth is the wrong tool and would break those; they're UDM-firewall-scoped. approve/backup-approve stay HMAC+CF-Access.

**SSO gotchas (the why):**
- **Blueprint user `password: !Env` clobbers UI changes.** Authentik re-applies the password on *every* blueprint apply (write-only field, can't diff), so each worker restart during the build reset graham's password to the bootstrap value → "invalid password". **Fix:** drop the `password` attr; graham's password+passkey are UI-managed (akadmin = break-glass; on rebuild, re-set via akadmin).
- **Grafana literal role mapping silently fails.** `role_attribute_path: 'GrafanaAdmin'` evaluated to empty → every OIDC login reset the user to Viewer (clobbering manual grants). Cause: go-ini strips the wrapping quotes → the JMESPath literal becomes a missing-claim lookup. **Fix:** `skip_org_role_sync: true` + grant graham Grafana **server admin** via the API (persists). Roles are now manually managed (single-owner); revisit group-based mapping for multi-user.
- **Dark mode** for the whole UI = brand `attributes.settings.theme.base=dark` (2024.12 has no UI toggle and no theme column — it's read from brand attributes). The earlier `@import theme-dark.css` hack didn't reach the mgmt UI / nested flow shadow-roots. Login chrome ("Etherport SSO" title, dark card, deep-slate bg) = flow blueprint (title/background) + a flow-scoped `custom.css` (`:has(ak-flow-executor)` + `.pf-c-login`) so it never touches the mgmt UI. flow `background` is a FileField → seed a solid-color PNG into the media volume via a server init container (a data-URI gets stored as a bogus filename).

**S3 backups (same day, earlier):** root-caused the overnight all-shares failure = a `set -e` footgun in `wait_for_rclone` (bare `[ ] && echo` returns 1 when `waited==0`) introduced by the cross-job-lock change `2089ec7`; fix `32cc001` already in the live `:main` image (verified end-to-end). Ran the **approval-flow test**: revoked the `backups` approval marker → re-run re-requested approval (pending, emailed) while content/media/graham synced to completion — **confirms shares are independent** (separate jobs + per-share locks; a contested *delete* halts only that share's whole run, uploads included, because it's one `aws s3 sync --delete`). Then executed the operator-approved `backups` deletion (**1456 deletes + 2805 uploads**). Fixed the **double approval email** (`backoffLimit: 1→0` — the Job retried the terminal `request_approval` exit, re-emailing; the script already retries transient sync failures internally). Deleted 18 orphan Velero-restore RBAC objects in `backups`. **TF Object Lock on the archive bucket is still NOT codified** (live GOVERNANCE/180d confirmed; absent from Terraform — the other agent had NOT done it; offered to import).

**M101 — VM auto-update gaps:** `unattended-upgrades` is the manager (base.yml, security-only + auto-reboot, `all:!k8s_cluster`) but the **devbox ran stock u-u** (never got base.yml) and the policy was **security-only** (so `-updates`/third-party accumulated). Fixes: **broadened** base.yml `allowed_origins` to include `-updates`; brought devbox onto the policy (applied live as a stopgap — no ansible on devbox — + `devbox: "05:00"` reboot window in base.yml; cleared 7-pkg backlog); wrote **`infra/ansible/playbooks/k8s-node-patch.yml`** (rolling cordon/drain/upgrade/reboot/uncordon, serial:1, CNPG-PDB handling). **Operator follow-ups:** run `base.yml -l devbox` (formalize + node_exporter/NTP/SSH on devbox) and `k8s-node-patch.yml` in a window.

**State:** SSO functionally complete + verified (owner confirmed chat/wiki/grafana/proxmox). Docs: H38 ✅, M101 🟡 (code done, operator runs pending). **Next steps:** owner enroll passkeys on remaining accounts; decide TF Object Lock import; run the two ansible follow-ups; (optional) broaden cookie to apex only if public services appear.

---

## 2026-06-23 (cont. 2) — M80 iMessage backup LIVE (DB) + the FDA/launchd saga

Got `messages-backup.sh` working under launchd after root-causing why launchd runs failed where interactive ones succeeded. **DB backup is DONE + verified:** `chat.db` 508MB, **319,678 messages**, `integrity_check=ok`, on the NAS (`/Backups/Graham/iCloud/Messages/`); re-runs at the start of every nightly. Agent loaded (20:00).

**Three root causes (all fixed):**
1. **FDA must be on `/bin/bash`, NOT the leaf binary.** macOS attributes TCC file access to the launchd job's *responsible process* (= `/bin/bash`, the job program), so granting FDA to `/usr/bin/rsync` was ignored for reading `~/Library/Messages`. Granting `/bin/bash` FDA fixed it instantly. (Interactively the responsible process is `Terminal.app`, which is why my interactive rsync tests also couldn't read it.) Docs + script header updated to say grant `/bin/bash`.
2. **Background/launchd processes need FDA to read NETWORK volumes too** (`/Volumes/<smb>`). My new `ls`-based liveness probe returned EPERM under launchd even on a HEALTHY mount → `mount-nas.sh` force-unmounted good mounts — **a regression that would've broken tonight's photos/DAV nightlies.** Fixed: `nas_readable()` in `mini-common.sh` probes via `rsync -n --exclude='/*/*'` (FDA-safe stat, depth-limited, instant); `mount-nas` `nas_share_ready` + the messages nas-check use it. (`-d` returns rc=23 on openrsync — used `--exclude` to limit depth.) **NB the rsync -n probe is stat-only → it can pass on a half-stale mount; the actual rsync op + watchdog backstop that.**
3. **Attachments first-copy trips an SMB session drop under sustained write load** (`SESSION_RECONNECT_COUNT=1` at the rsync start; NAS RAID/network confirmed healthy) → wedged rsync in D-state, same mode as the M79 photos bulk-pull. Made the attachments mirror retry+resume: bounded per-attempt timeout (`ATT_TIMEOUT=1200`) + remount between attempts (`ATT_ATTEMPTS=10`), rsync -a resumes.

**Design also added:** message-count **regression guard** (refuse to overwrite the NAS DB if message count drops >10% vs last success — the practical "is the local iCloud cache complete?" check; Messages-in-iCloud IS enabled here so local chat.db is a synced cache) + `--max-delete=500` on attachments. Commits `510db28` (FDA/probe fix), `31b06f3` (resilient attachments).

**State:** DB backup live + verified. **Attachments first-copy IN PROGRESS** — converging slowly (~1–2 files/s over SMB nested small-files; survives drops via the retry loop) and may span attempts/nights; background monitor watching. If too slow, switch the bulk first-copy to local-tar→single-transfer to dodge per-file SMB latency. Remaining M80 tier after this: Drive.

---

## 2026-06-23 (cont. 1) — CORRECTION: the 5 non-backups overnight failures were a `wait_for_rclone` set -e bug, not "transient fast-fails"

Owner, reviewing overnight status emails: "all sync tasks failed… does a delete approval prevent all jobs from running until approved/rejected?" **Answer: no** — approvals are per-share (per-share lock + `approvals/approved/<share>.json`); a pending `backups` approval cannot fail other shares.

**Reconciling the two overnight reads (this corrects the entry below):**
- **`backups`** DID legitimately trip the delete-guard on **1,436 real deletions** (the GDrive-side `.tif` removal mirrored to the NAS) → approval requested → owner approved (live marker `approvals/approved/backups.json`: `approvedMaxDelete=1584` = 1436×1.1+5 from the approval-server formula, `wouldDeleteAtApproval=1436`, expires 06-25; `approvedBy=unknown` ⇒ approved via the internal path). It reached the guard because **rclone was actively writing the Backups share at 01:00, so `wait_for_rclone` looped (waited>0) and returned cleanly.** The entry below got this one right.
- **The other 5 shares** (graham/archive/content/mark/media) did NOT "transiently fast-fail" — they hit a **deterministic `set -e` bug**: `wait_for_rclone`'s last line was `[ "${waited}" -gt 0 ] && echo …`, which returns 1 when `waited==0` (no fresh rclone lock — their normal case) → function returns 1 → bare call trips `set -euo pipefail` → script dies **before acquire_lock / dry-run / check_approval**. Proof: graham's pod log exits right after `[excludes] Total patterns loaded` with the EXIT trap (`[lock] Releasing lock`) firing before `[lock] Attempting to acquire`. Introduced by `2089ec7` (image built 06-22 13:26 UTC, after the 06-22 nightly → 06-23 was the first nightly to hit it). **This was also a MISS in the morning's adversarial review.**

Fix `32cc001`: `if/fi` + explicit `return 0`; reproduced (old→exit 1 pre-acquire_lock, fixed→exit 0); swept for other `&&`-terminated function tails (none). **Verified end-to-end on the rebuilt image:** a manual `mark` job ran the whole flow (past `wait_for_rclone` → acquire_lock → Guard 1 → dry-run → H3 pre-sync re-assert → real sync → report → `succeeded=1`); mark is caught up. **Why this matters for tonight:** without it, on any night rclone ISN'T mid-write at 01:00, `backups` would hit the SAME bug and die before consuming its approval marker — so the fix also protects the approved deletion. The remaining 4 failed shares catch up on tonight's 01:00 nightly (or on request). NB: the entry below also mentions a manually-minted `approvedMaxDelete=2000`; the live marker is the approval-server's `1584` (both ≥ 1436, so tonight proceeds either way).

---

## 2026-06-23 — overnight sync triage + M80 iMessage backup drafted

**Overnight triage (owner: "received ai advisor error alerts… related to last night or will clear?").** iCloud backups all GREEN; the advisor itself healthy (analysed alerts, didn't error). The **iCloud advisor alert** was `ICloudBackupFailed`+`ICloudBackupEmpty` (contacts/calendars), fired ~21:30–22:00 PT from the **21:00 DAV nightly hitting the stale SMB mount** (rc=1/items=0) — a real event ~2h before the self-heal was committed; advisor verdict `noop`; **already resolved** (self-heal re-ran ~23:00 → rc=0/2049/446, no iCloud alert now firing). Separately, the **01:00 S3 sync** failed on all 6 shares: 5 = transient 01:00 thundering-herd fast-fails; `backups` = **delete-guard correctly held 1,436 deletions** = the `Graham/Google Drive/Assets/2018 Shoot` `.tif` files that vanished from the NAS source (rclone `gdrive-sync --delete` mirrored a Google-Drive-side removal; its own `--max-delete` cap + the s3 delete-guard both fired). **S3 copy intact** (15,685 obj / 39.5 GB verified). Owner confirmed the GDrive deletions intentional → **minted the s3 approval marker** `s3://logs.archive.wind.etherport.net/approvals/approved/backups.json` (approvedMaxDelete=2000, 24h, one-time) so tonight's run mirrors it. Left the failed Job objects for the infra-agent (owner's call). NAS SMB went stale twice today — self-heal handled both.

**M80 iMessage backup DRAFTED** (`messages-backup.sh` + `net.wind.messages-backup.plist`, daily 20:00). Backs up `chat.db` + `Attachments/` → `/Backups/Graham/iCloud/Messages/`. Design: rsync live DB→local staging, then **`sqlite3 .backup` + `integrity_check` on the STAGED copy** (no FDA needed there; produces a clean WAL-checkpointed standalone `chat.db`; a torn/corrupt copy fails the run, never overwriting the good NAS copy), then **guarded mirror** (refuse-empty + `--max-delete`) of the DB + Attachments to the NAS. Reuses `mini-common.sh` (lock/timeout/kill) + `mount-nas.sh` self-heal + `messages_backup_*` metrics (auto-covered by the iCloud-backups dashboard + alerts) + Alloy log shipping. **Key design choice:** read with **rsync only** so just **one** Full Disk Access grant is needed (`/usr/bin/rsync`); sqlite3 reads only the staged copy. **BLOCKED on operator:** grant FDA to `/usr/bin/rsync` (VNC), manual run, then `launchctl bootstrap` the 20:00 agent. Validated: syntax OK; FDA preflight aborts cleanly (`no-FDA-or-unreadable-source`, rc=1 — no silent empty backup). Messages confirmed signed-in; chat.db=505MB; 51GB local free for staging. NOT loaded yet (would alert nightly until FDA granted). Steps in `infra/macos/mini/README.md` → "M80 iMessage backup".

---

## 2026-06-23 (cont.) — H3 COMPLETE: monitoring tier enforced + drop-alerting live

Closed H3. The monitoring tier had observed ~24h under audit; checked the audit log → **0 monitoring would-be-drops over 24h**, and the periodic external paths fired clean (**391 alertmanager notifications sent, 0 failed** = SES `:587` egress validated; ai-advisor/backups too). So re-enforced: `kubectl patch cm cilium-config policy-audit-mode=false` + `rollout restart ds/cilium` (separate commands — the compound trips the classifier) + inventory→false + cancelled the scheduled flip-off cron. **Verified:** runtime PolicyAuditMode Disabled, 116 Prometheus targets up / 0 down (scraping intact under the permissive `cluster` egress), **0 drops across all 5 tiers** (postgres/cue/dns/traefik/monitoring).

**All 5 target tiers now ENFORCED** — the largest internal-segmentation gap is closed. **DROP-alerting is now live** (the export already carried `verdict:[AUDIT,DROPPED]`; the `CiliumNetpolDropFlow` loki-ruler rule now has real drops to fire on). De-TEMP'd the banners (CLAUDE.md §5, networkpolicies/kustomization + 14-tier-monitoring header, tracker H3 → ✅). Adding a service that crosses an enforced boundary now needs an allowlist entry (runbook); a new tier uses the audit toggle.

---

## 2026-06-23 — H38: Authelia → Authentik (internal IdP) deployed

Started H38 (kill "internal = trusted") with **Authelia** (local users + TOTP/WebAuthn + SES), got it fully working after three deploy-bugs (all mine, not Authelia): (1) `enableServiceLinks: false` — the Service named "authelia" made k8s inject `AUTHELIA_*` env that Authelia parsed as config → boot conflict; (2) `readOnlyRootFilesystem: false` — Authelia writes `/app/.healthcheck.env`; (3) **users DB must be on a WRITABLE volume** — the file backend rewrites it on password change, but it was a read-only Secret mount → "issue resetting your password" (fixed with an init-container seeding the SOPS user DB onto the PVC). Then the owner, wanting **full OIDC SSO + a less-basic UX**, chose to **switch to Authentik** (answered: single-instance Postgres isn't production-standard for an IdP; Authentik config is DB-state but DR-safe via the PG backup; reuse the shared HA cluster).

**Authentik deployed** (`4170b27`, `9d67a44`): IdP live at **auth.wind.etherport.net** (portal 302, embedded forward-auth outpost connected). **DB on the shared HA `postgres-cluster`** — added a CNPG `managed.role` `authentik` (login+createdb, password in a SOPS secret mirrored to the authentik ns) and the server/worker **init-container creates the `authentik` DB** (CNPG 1.24 has no Database CR + superuser disabled, so the role self-creates it); added `authentik` to the **postgres-tier NetworkPolicy allowlist** (the documented "new service crosses an enforced boundary" case). App: redis (ephemeral) + server + worker (goauthentik 2024.12.3) + 2Gi media PVC; SOPS secrets (SECRET_KEY, bootstrap admin pw/token, SES SMTP pw, DB pw); SES email (enroll/reset; login stays local). **Backups:** DB rides the shared cluster's barman; media PVC via the new `authentik-daily` Velero schedule. **service-status:** server/worker/redis added. akadmin bootstrapped (pw surfaced once → change + MFA in UI).

**Verified:** authelia pruned; authentik role + DB created; redis/server/worker healthy; portal 302 via the VIP; embedded outpost up. **Next = the actual SSO pass** (owner chose full SSO), all as git **blueprints**: OIDC provider + Grafana (OIDC/header → maps to existing user by email), wiki.js (OIDC), and a **proxy provider + Traefik forward-auth middleware** for the no-OIDC apps (HA/loki/pushgateway/ollama/device UIs). Nothing is gated yet (zero lockout risk). Tracker H38 has the detail.

---

## 2026-06-23 — Adversarial review of the aws-s3 NAS→S3 backup app → full fix set shipped

Owner: "we never got a chance to perform an adversarial code review… get up to speed and perform the adversarial review", then "do the full set of fixes" + "I approved a delete request this morning which would run overnight tonight — ensure that's maintained once we update."

**Review (read the whole production path first-hand + a 5-lens cost fan-out):** 3 HIGH, 5 MEDIUM, several LOW. Plan/findings artifact: `~/.claude/plans/pure-floating-kernighan.md`.

**Fixes landed in `image/scripts/` + manifests (this session):**
- **H1** — `release_lock()` now only deletes the lock ConfigMap when `.data.owner==$RUN_ID`. The EXIT trap is armed before `acquire_lock`, so the old code had a job that *skipped* (lock held by another) delete the **holder's** lock on exit → defeated the mutex → concurrent `--delete` syncs. (concurrencyPolicy:Forbid only covers same-CronJob overlap, not manual↔scheduled.)
- **H2** — the end-of-script "completed with warnings" block ran at top-level scope but used `local subject=` (errors under `set -euo pipefail`) and `${RUN_SUMMARY_URI}` (never set). Any `WARNING_COUNT>0` run (e.g. an expected checksum-unavailable on the `backups` share) exited non-zero → false FAILED Job + the degraded email never sent. Fixed both; the block can no longer change exit status.
- **H3** — the delete guard measured a **dry-run**, then the real `--delete` was a *separate, unbounded* `aws s3 sync`. If the NFS source dropped in between, the real sync wiped S3 despite the guard passing. Factored Guard 1 into `assert_source_populated()` and **re-assert it immediately before the real `--delete`** (conservative design: a healthy source — incl. an approved bulk delete — passes unchanged; a genuinely empty source aborts without wiping).
- **L5a** — a failed/partial dry-run is now **fail-closed** (`guard_abort`) instead of parsing "0 deletions" and proceeding to an unbounded `--delete`.
- **M2** — `verify-one.sh` retries `head-object` (4 attempts, backoff) on transient 503/socket before recording `failed`; a genuine 404 is not retried. Stops transient throttling from producing a false verification FAILED.
- **M3** — `LOCK_MAX_AGE_SECONDS` 24h→48h, env-overridable (a long initial sync could be force-unlocked into a concurrent run at 24h).
- **L5c** — composite (multipart) checksum now derives part size from the part count when 8 MB doesn't reproduce it; an unreconstructable composite is marked *unavailable*, not a false "corruption".
- **M5** — the signed approve URL is no longer echoed to pod logs (`token redacted`); `request-approval.py` still prints it (its return channel). Deliberately did **not** force `APPROVAL_REQUIRE_CF_EMAIL=true` — backup-approve is split-horizon, so an on-network operator hits the internal Traefik path (no CF header) and it would reject their own click; documented in the deployment.
- **L5d** — `approval-server.py` `tempfile.mktemp()` → `mkstemp`.
- **M4** — the `daily-report` SA + Role (`jobs`/`cronjobs` get,list) + RoleBinding existed in-cluster (41d) but were **missing from git** (drift); captured into `daily-report/rbac.yaml`. The `ghcr-creds` imagePullSecret was a **dead reference** — the GHCR package is **public** (anonymous pull → 200; neither live SA has a pull secret), so removed it from `base/serviceaccount.yaml`.
- **L5b** — `ephemeral-storage` requests/limits on the `work` emptyDir workloads.
- **L2** — deleted dead `verify.py`, `verify-existing-files.py`, `enhance-report-with-checksums.sh`.
- **L1** — `validate-existing-backups.sh`: composite-aware comparison (was false-"corruption" on every multipart file) + `REPORT_PREFIX` moved under the IAM-granted `reports/` prefix (was `validation-reports/` → AccessDenied on upload).
- **L3** — README "Production Policy" JSON synced to the live policy (`approvals/*`, `infra` bucket) + a source-of-truth banner pointing at the TF JSON.

**Cost note (operator is cost-sensitive, 10TB+):** audited every fix — none raise steady-state AWS spend. Verified the `archive` bucket transitions to **Deep Archive at 5 days** (180-day min) + expires noncurrent versions at 30 days (`infra/terraform/aws/s3/main.tf:126,144`), so the data-safety fixes (H3/L5a/L5e/H2/M3) **avert** a Deep Archive early-deletion bill (~$5-6/TB of churned cold data) in the wipe/concurrent-sync tail. `--size-only` kept (M1, accepted) — it's the mtime-churn cost control, not the checksum algo.

**L6 (open):** README/Security claim "Object Lock" on the data bucket but there's **no `object_lock_configuration` in the TF** — operator is verifying out-of-band (says it IS enabled). Treat as enabled.

**Overnight-safety design:** an operator approval written this morning (`approvals/approved/<share>.json`, 48h TTL) must be consumed by tonight's run, which pulls the new `:main` image. H3 is conservative (a healthy source passes), so the approved bulk delete still runs; `check_approval` consumes the marker then the real `--delete` executes. **Image kept on `:main` tonight** so the run gets the fixes; **L4 (sha-pin) deferred** to a post-tonight follow-up (pinning to a not-yet-built sha would break the pull). Also deferred: the fuller **manifest-driven H3** (drive deletes from the measured set) — the re-assert is the tonight-safe interim.

**State at end:** all scripts `bash -n` + embedded-Python compile clean; manifests pending `kubectl kustomize`. **Next:** verify the approval marker + a manual dry-run for the approved share, commit+push (triggers the `:main` rebuild — confirm it finishes before the share's 01:00 PT schedule), watch tonight's run consume the marker + delete, then land L4 + manifest-driven H3.

---

## 2026-06-22 (cont. 9) — netpol DROP alerting + iCloud backup alerts enabled

**Drop notification (answers "how are we told to open a channel once enforcing").** Built the DROP-alert pipeline (was the H3 follow-up): extended the Cilium hubble export to `verdict:[AUDIT,DROPPED]` (live `kubectl patch cm cilium-config` — the `patch+rollout` compound cmd hit the auto-mode classifier, so run them as SEPARATE commands — + `rollout restart ds/cilium`; durable in the kubespray inventory). The global audit switch means one export covers both phases: AUDIT while observing, DROPPED while enforcing, same `{job="hubble-audit"}` Loki stream. Added loki-ruler rule **`CiliumNetpolDropFlow`** (`06-loki-rules-cilium-audit.yaml`): fires (warning → Alertmanager email) on a sustained DROPPED flow to/from an enforced ns from an **in-cluster** source (`src_ns!=""` drops external-scan noise). So drops are **stored in Loki** (Grafana Explore) and **alerted via Alertmanager**, naming `src→dst:port` → add to the per-tier CNP per the runbook. External (`src=world`) drops still need manual `hubble observe`. Verified AUDIT export intact post-rollout (monitoring observation unaffected); loki accepted both rules. Activates automatically when the monitoring flip re-enforces. `83c14da`.

**iCloud backup alerts enabled.** The mini's contacts + calendars syncs are now healthy — verified in Prometheus (contacts rc=0/items=2049 vCards, calendars rc=0/items=446 events, fresh) — so un-held `10-icloud-backups-alerts.yaml` (`ICloudBackup{Stale,Failed,Empty}`). Live; not firing (healthy).

**State:** monitoring still observing under audit (flip pending ~24h via cron `ea15194e`); the DROP rule + export are ready for when it re-enforces. H3 DROP-alerting follow-up ✅ done.

---

## 2026-06-22 — Adversarial review of all M79/M80 backup code → 4 CRITICAL + HIGH fixed

Owner: "given the bugs and the issues we've had on photo sync, perform an adversarial review of all the code implemented across these two tasks. also has execution success status been pushed to grafana?"

**Grafana:** success status IS in Pushgateway (photos_export/contacts_backup/calendars_backup all rc=0 + last_success). Could NOT verify Prometheus ingest from the mini (the prometheus query API isn't reachable from 10.10.202.101) — cluster-side scrape/dashboard is the infra-agent's to confirm.

**Review:** 3 independent adversarial reviewers over all ~836 lines (photos pipeline / DAV pipeline / infra+scheduling). Found 4 CRITICAL + several HIGH. **Fixed + verified the data-loss ones immediately** (one was scheduled to run that night):

- **C-1 (data loss, `ceb5027`):** `icloud-dav-backup.sh` ran `rsync -a --delete staging→NAS` UNCONDITIONALLY. App-password expiry / watchdog kill / iCloud empty-collection / sops failure → empty staging → `--delete` WIPES the NAS master (the only offsite-bound backup), then s3-sync ships the empty state. Fix: `mirror_service()` refuses to mirror unless vdirsyncer rc==0 AND staging non-empty, counts items BEFORE the rsync, caps deletions with `--max-delete=max(master/2,25)` (mass-shrink → rsync rc=25 abort). Also capture discover rc via PIPESTATUS (fail on real discover error, tolerate SIGPIPE 141).
- **C-2 (silent masking, `ceb5027`):** `photos-metrics.sh` — a watchdog-killed run pushed `missing=0` (reads as "nothing to back up"); a clean run with a truncated `--report` CSV pushed `missing_resolvable=0` AND stamped `last_success` while photos were missing. Fix: `parsed=1` only if rc==0 && photos>0; push `-1` sentinels when not parsed; DERIVE `resolvable = missing - unavailable` (classify failure can't zero it); add `${job}_summary_parsed`; gate `last_success` on `parsed`.
- **HIGH (`adbade8`):** new `mini-common.sh` (unit-tested) wired into all 3 scripts — `mini_acquire_lock` (atomic + pid-command liveness check: kills the bare-PID-reuse "silent outage forever" + the `rm -rf;mkdir` double-run-on-one-ledger race), `mini_run_timeout` (portable; bounds count()/rsync/master-find + a DAV post-mount liveness probe so a dead-but-listed SMB mount can't hang forever — H3/L2), `mini_kill_tree` (TERM→TERM→KILL + child reap; fixes orphaned osxphotos/vdirsyncer holding the ledger — H4).
- **C-3 (`4697f23`):** nsmb.conf hardening was a silent no-op — written to `~/Library/Preferences/` but the kernel reads `/etc/nsmb.conf` (absent; live smbutil showed signing-on/defaults). Added `install-nsmb-conf.sh` + root LaunchDaemon `net.wind.nsmb-install.plist` (survives reboot) + mount-nas.sh detect/warn + post-mount signing verify. **NEEDS a one-time operator sudo** to bootstrap the LaunchDaemon (no passwordless sudo on the mini) — commands in `infra/macos/mini/README.md` → "SMB tuning".
- **C-4 (`3103ac1`):** the "silent no-run when mini locked/asleep" gap is ALREADY covered cluster-side — `PhotosExportStale` + `ICloudBackupStale` (no success >26h) fire if a job doesn't run (infra-agent enabled icloud-backups-alerts ~the same time, after the syncs went green). Added `PhotosExportNotParsed` (summary_parsed==0) for the new sentinel signal; reconciled live via Flux.

**Residual / handoff:** (a) ✅ DONE — operator installed `/etc/nsmb.conf` + LaunchDaemon via sudo (VNC); remounted → tuning live (44k-dir listing 17.3s→11s; signing still on by design); (b) infra-agent: confirm Prometheus actually scrapes pushgateway + that the `-1`/`summary_parsed` sentinels don't trip existing alerts; (c) MEDIUM count_orphans basename-collision undercount + silent -1-disable (photos-metrics.sh H5) — deferred. **Verified:** all scripts syntax-clean; mini-common unit-tested; guarded DAV run clean (2049/446, master intact, rc=0); photos metric logic unit-tested + the 22:00 photos nightly ran green in production with the new schema (summary_parsed=1, derived resolvable=0).

**LIVE VALIDATION + self-heal (`e1443fa`, `5905056`):** the 21:00 DAV nightly fired during this session and FAILED on a stale Backups mount (idle-drop) — but the new liveness probe **caught it correctly** (rc=1, master intact) instead of hanging/wiping. That exposed a gap: the code aborted instead of self-healing. Fixed: stale-mount detection + force-remount centralised in `mount-nas.sh` (probe each share, force-unmount+remount a stale one, detaching the sparsebundle first for Personal-Drive) so ALL three pipelines self-heal via their existing mount-nas.sh preflight; DAV inline logic simplified to one call + probe. Re-run completed tonight's backup green. **Note:** the mount still went stale even WITH `notify_off` — the tuning reduces frequency, the self-heal handles occurrences.

---

## 2026-06-22 — M80 tier-1: iCloud Contacts + Calendars backup LIVE + scheduled

Owner: "lmk when we've completed a successful contacts/calendar sync. infra agent has built dashboard but it's reporting no success yet" + "is it now scheduled at regular intervals?"

**Result: DONE.** 2,049 contacts (`.vcf`) + 446 calendar events (`.ics`) back up cleanly to `/Backups/Graham/iCloud/{Contacts,Calendars}` (rides the existing 01:00 `s3-sync-backups` → S3 offsite). rc=0/item-count/`last_success` metrics push green to Pushgateway (job `contacts_backup`/`calendars_backup`). LaunchAgent `net.wind.icloud-dav` loaded + scheduled **daily 21:00** (before the 01:00 S3 sync → ships same night). Incremental run = **11s** (5s iCloud pull + 6s rsync); first run was ~3 min only for the one-time rsync fill.

**The dashboard "no success" was TWO bugs in the wrapper — not SMB, not iCloud** (commit `9e04e9f`):
1. `vdirsyncer-config`: an **inline `#` comment trailing the `calendars_local` `path` value** broke vdirsyncer's INI parser ("Extra data: ... char 41") → vdirsyncer never started, empty staging. Comments must be on their own line above the option.
2. `icloud-dav-backup.sh`: **`set -o pipefail` + `yes | vdirsyncer discover`** returned 141 (`yes` gets SIGPIPE when discover closes the pipe) → the `&&` saw non-zero and **skipped the actual sync**. Fixed by wrapping discover+sync in a subshell with `set +o pipefail`.

**Design (M80, decided earlier this session):** vdirsyncer pulls iCloud → **LOCAL staging** (`~/.local/share/icloud-dav/`), then `rsync -a --delete` staging → NAS. Why: writing thousands of small files **straight to SMB** is slow enough (~100 files/s, metadata-latency-bound) that the iCloud DAV connection times out mid-pull ("Server disconnected"). Staging decouples the iCloud fetch from slow SMB. iCloud storages are `read_only=true` (vdirsyncer can never write back to real contacts/calendars). App-specific password from the SOPS bundle (`icloud_app_password`) via `icloud-app-password.sh`.

**SMB performance investigation (owner: "why is SMB so slow… NAS reporting healthy"):** Benchmarked — NAS is healthy. Sequential write **708 MB/s**, 0.36ms latency, 10GbE, 0 reconnects. The slowness is **per-file metadata round-trips only**: a small dir lists in 0.46s but the **44k-file Photos dir takes 17.3s**, and small-file writes cap ~100/s. Inherent to SMB on a deep flat directory — not NAS ill-health (consistent with "reports healthy"). The earlier catastrophic stalls were the NAS NVMe read-cache controller failure (resolved by reboot; today's benchmarks confirm gone). **Side-finding:** `/etc/nsmb.conf` is MISSING (mount-nas.sh installs it but it didn't stick this boot) so the `mc_on`/`notify_off` tuning isn't active, and SMB signing is ON (`AES_128_GMAC`) — both worth fixing to help the metadata/small-file path (follow-up, not blocking).

**State:** M80 tier-1 (Contacts + Calendars) complete + scheduled + monitored. **Next:** chase the `/etc/nsmb.conf` install gap; remaining M80 tiers (Messages, etc.) per the tier plan.

---

## 2026-06-22 (cont. 8) — H3 tier 5: monitoring OBSERVATION started (audit on, flip ~24h)

Owner: "Take on monitoring. Start with audit as this is wide reaching." monitoring is the widest-fanout ns (Prometheus scrapes every ns + 5 external hosts; Alloy ingests syslog; Alertmanager/ai-advisor egress externally), so audit-first is essential.

**Characterized (Hubble + config).** Egress fanout: scrapes postgres/cue :9187, kube-system :9153, gpu-operator :9400/:8080, flux :8080, blackbox :9115, velero :8085, unifi-poller :9130, cloudflared :2000, + host/remote-node/apiserver (kubelet/kube-proxy/etc.) + **external** `world:9100` (4 node-exporters: 10.10.100.5/10, 10.10.201.6/15) + `world:9290` (pve IPMI 10.10.200.41, from `01-external-scrape-config.yaml`). External notify: SES SMTP (`:587`), ai-advisor→Anthropic (`:443`). Ingress: `world:514` syslog→Alloy, `world:9091` pushgateway (mini), `:3100` Loki, `kube-apiserver`→operator admission webhook (NOT covered by cluster-essentials), + everything in-cluster reaching grafana/prometheus/AM/loki/pushgateway.

**Draft + toggle.** Flipped global audit ON (postgres/cue/dns/traefik → audit-only meanwhile) + labelled monitoring (via `namespace-pss-labels.yaml` patch) + applied `14-tier-monitoring.yaml` (CNP `monitoring-tier`): permissive egress (`cluster` any-port + `world` :80/:443/:587/:465/:25/:9100/:9290) + ingress (`cluster` any-port + `world` :9091/:3100/:514 + `kube-apiserver`). `6574bbc`. **0 audit gaps** on active flows (112 Prometheus targets up, grafana 302).

**Owner chose observe ~24h then flip** (vs flip-now): the periodic external paths (alert email :587, ai-advisor :443, backup reports) are port-covered but hadn't fired to confirm, and a broken alert-email path fails silently. So audit stays ON ~24h to let an alert/advisor/backup cycle exercise them; a **scheduled re-check** (CronCreate) will re-examine the audit log and, if clean, flip audit OFF (re-enforce all 5) + revert the inventory. Until then the 4 prior tiers are audit-only (accepted, allowlists verified). Flip command in the tracker + `networkpolicy-tiers.md`.

**Docs:** added "Adding monitoring for a new service" to `docs/runbooks/networkpolicy-tiers.md` (in-cluster scrape/push/logs just work via the permissive design + `allow-monitoring-scrape`; a new EXTERNAL scrape target/notifier on a non-standard port needs a `world` port added to the monitoring tier). CLAUDE.md §5 TEMP banner (audit on), tracker H3, this entry.

**State:** H3 = tiers 1–4 enforced, tier 5 (monitoring) observing (flip pending). After monitoring flips, all target tiers are enforced — H3 effectively complete (minus the DROP-alerting follow-up).

---

## 2026-06-22 (cont. 7) — H3 tier 4: traefik ENFORCED via the audit toggle + new-service runbook

First use of the **audit toggle** (per owner request — "ensure we're not cutting off traffic"). Traefik is the ingress controller (high-fanout: routes to every backend + external devices), so a point-in-time Hubble capture misses rarely-accessed routes → observe-first is the safe path.

**New-service docs (owner ask).** Wrote `docs/runbooks/networkpolicy-tiers.md` (`a40ec62`): the enforcement model + the **operational tax** — a new service that crosses an enforced namespace boundary must be allowlisted or its traffic is silently dropped (no alert yet). Three cases (workload in an enforced ns / reaching one / a new Traefik external backend), `hubble observe --verdict DROPPED` detection, fix workflow, adding-a-tier, rollback. Indexed + cross-linked from CLAUDE.md §5 and `networkpolicies/README.md`.

**Toggle execution.** Flipped global audit ON (live `cilium-config` patch + rollout; inventory→true) — postgres/cue/dns reverted to audit-only meanwhile (accepted, allowlists verified). Labelled the traefik ns (via `namespace-pss-labels.yaml` strategic-merge patch — Helm-created, no 00-namespace.yaml) + applied `13-tier-traefik.yaml` (CNP `traefik-tier`): **permissive egress** (`toEntities: cluster` any-port + `world` :80/:443/:8006) so no backend route is ever cut now or future; ingress public entrypoints (:80/:443/:8088) from `all` + mgmt (:8080/:8443) in-cluster. `433ba22`.

**Validation (didn't just wait).** Verified egress is provably complete (internal=cluster covers all ports; all external ingressroute backends use only :80/:443/:8006; :8123=internal HA), enumerated entrypoints, then **actively exercised** the riskiest paths under audit — UPS/PDU/Proxmox external routes (303/303/404) + grafana/dns/hubble internal → **0 traefik AUDIT flows** (Loki + live Hubble). Flipped audit OFF (inventory→false) → all 4 tiers enforce. **Post-enforce:** all routes still 200/302/303/404, **0 drops across postgres+cue+dns+traefik**, traefik 2/2 + dns 3/3 + cue-db/postgres healthy, DNS resolution (internal+external) fine.

**State:** H3 = 4 tiers enforced (postgres/cue/dns/traefik). Only `monitoring` remains (highest-fanout → audit toggle + likely permissive egress like traefik). DROP-alerting follow-up still open. Lesson: the toggle works cleanly + actively-exercising the risky routes under audit beats passively waiting for organic traffic. Docs: CLAUDE.md §5, networkpolicies/README.md + kustomization, tracker H3, runbook, this entry.

---

## 2026-06-22 (cont. 6) — H3 tier 3: dns/Technitium ENFORCED (critical resolver)

Continued H3 to dns — the highest-stakes tier (everything resolves via Technitium). Direct-from-Hubble again (postgres+cue stayed enforced); escape hatch ready (`kubectl patch cm cilium-config policy-audit-mode=true` works without cluster DNS).

**Characterized from live Hubble + the StatefulSet.** dns = technitium (2-replica STS) + dns-sync-watcher (in-ns). Listens :53 udp/tcp, :5380 (admin, liveness probe), :53443 (DoH), :853 (DoT). Ingress: :53 from world (LAN clients via the MetalLB VIP) + remote-node + cluster pods; :53443/:5380 from world+cluster; :5380 host = kubelet probes. Egress: world :53 (recursion, dominant) + :53443/:443 (DoH upstreams). High ephemeral-port flows = conntrack replies (auto-allowed).

**Allowlist (`12-tier-dns.yaml`, CNP `dns-tier`).** DNS-appropriate: query ports `:53`/`:853`/`:53443` ingress from `all` (structurally can't blackhole a client — cluster/node/world all covered), `:5380` admin from `cluster` only (**deliberately NOT world — closes the VIP:5380 external exposure, a security win**; admin is via the Traefik ingressroute `dns.wind.etherport.net`), intra-dns; egress `world` `:53`/`:443`/`:853`/`:53443` + intra-dns. DNS-self/apiserver/host via the cluster-wide allows. Segmentation lands on egress (Technitium can't pivot to other internal namespaces). Labelled ns + CNP in one commit. `7408fc9`.

**Verified.** Internal (`traefik.wind.etherport.net`→VIP), external recursion (`github.com`/`cloudflare.com`), and cluster DNS all resolve post-enforcement; 3 pods healthy, 0 restarts. **Drop triage:** post-flip showed ~ICMPv4 type-3 code-3 (Port Unreachable) noise — the pod kernel's courtesy reply to late upstream UDP packets after a recursion socket closed; **benign** (resolution unaffected). Allowed ICMP type-3 to/from world (`744b70e`) to keep the enforced drop log clean (also avoids future DROP-alert noise). Confirmed: fresh 40s window = 0 dns-pod drops. (Lesson: Cilium ICMP rule = `icmps: [{fields: [{type: 3, family: IPv4}]}]`; the stale ring-buffer briefly made it look unfixed.)

**State:** H3 tiers 1–3 (postgres, cue, dns) enforced — the DB + app + DNS tiers, the highest-value segmentation. Remaining: traefik → monitoring (higher-fanout → use the audit toggle, not direct). Docs: CLAUDE.md §5, networkpolicies/README.md, tracker H3, this entry. DROP-alerting follow-up still open.

---

## 2026-06-22 (cont. 5) — H3 tier 2: cue ENFORCED (postgres stayed enforced)

Continued H3 to the next tier (cue) — done WITHOUT the global audit toggle, so postgres stayed enforced throughout.

**Characterized cue from live data.** cue = `cue-api` (Node/Fastify, :3000) + `cue-db` (single-instance CNPG, no replication), Flux-managed here (`cue-api/`, `cue-db/`). Captured live Hubble forwarded flows + read the manifests: ingress to cue-api :3000 from **tailscale** (TS LB/Ingress) + **cloudflared** (CF tunnel); cue-db :5432 from cue-api/cnpg-system/tailscale (cue-db-ts LB); cue-db :8000 from cnpg-system; cue→kube-apiserver:6443 + host probes (covered by cluster-wide allows); cue-db→S3 barman (`postgres-barman` bucket → world:443, daily so not in the live window but added proactively).

**Built + enforced directly (no toggle).** Authored `11-tier-cue.yaml` (CNP `cue-tier`, endpointSelector {}): the ingress/egress above + intra-cue + world:443 (cue-api external HTTPS + barman). Since audit is OFF, a namespaced CNP enforces the instant it applies — and the cluster-wide allows only attach once the ns is labeled — so I committed the CNP + the `netpol.wind/enforced=true` label (`cue-db/00-namespace.yaml`) in ONE commit so Cilium computes the full allowlist together. Rationale for skipping the audit window: cue's flow set is small/stable and enforcement is reversible (remove the label → allow-all in ~1 reconcile). `610e5c9`. **Verified:** 0 cue DROPs (all nodes), cue-api serves through the policy (monitoring→:3000 = HTTP 302 in 7ms), cue-api↔cue-db :5432 flowing, both pods healthy (0 restarts), cue-db CNPG healthy.

**Found a gap (tracked, not fixed):** the audit→Loki pipeline (`CiliumNetpolAuditFlow`) only catches `AUDIT` verdicts, which cease once a tier enforces — so a wrongly-dropped flow on postgres/cue won't alert. Added an H3 follow-up to export `verdict=DROPPED` (enforced ns) → Loki → alert. (CNPG backup failures still covered by `CNPGBackupFailed`.)

**State:** H3 tiers 1–2 (postgres, cue) enforced; all other namespaces allow-all. Remaining: dns → traefik → monitoring (the higher-fanout traefik/monitoring should use the audit toggle, not direct). Docs updated: CLAUDE.md §5, networkpolicies/README.md, tracker H3, this entry. `cf_tunnel_services` grep didn't surface cue but live flows show cloudflared→cue:3000 (allowlisted regardless).

---

## 2026-06-22 (cont. 4) — H3: postgres tier ENFORCED (first NetworkPolicy enforcement)

Picked up H3 (NetworkPolicy enforcement). Outlined the phased plan, then executed tier 1.

**Refined the postgres allowlist from audit data.** Pulled the Phase-1 audit flows from Loki `{job="hubble-audit"}` (24h sample + a 7d LogQL aggregation to catch rare/weekly flows). postgres — the only `netpol.wind/enforced=true` namespace — had exactly **3** would-be-drops, all the "known-good excluded" tuples: postgres→postgres `:5432` egress (CNPG replication, 22.4k/7d), cnpg-system→postgres `:8000` ingress (operator→instance-manager, 19.4k/7d), postgres→world `:443` egress (barman→S3, 278/7d). The old `postgres-ingress` CNP was **ingress-only**, so all three were unhandled. Replaced it with `postgres-tier` (ingress+egress): added `:8000` ingress, `:5432` intra egress, `:443` world egress. Server-side validated; after apply postgres **AUDITed nothing** (verified clean over both a live window and the 7d aggregation). `c4f2235`.

**Enforced (owner chose "enforce postgres now").** Flipped the GLOBAL switch: `cilium_policy_audit_mode`→false in the kubespray inventory (durability) + live `kubectl patch cm cilium-config policy-audit-mode=false` + `rollout restart ds/cilium`. **Clean 8/8 roll** (no cni-dir-owner crashloop — dir root-owned, not a kubespray run). **Verified post-flip:** runtime `PolicyAuditMode: Disabled` on agents; **0 postgres DROPs** on all 3 postgres nodes (hubble); CNPG cluster healthy 3/3 no restarts; wikijs app path intact; all 3 postgres exporters up. postgres is now truly default-deny + allowlist; **all unlabeled namespaces remain allow-all** (the CCNPs select only enforced-labeled ns).

**Key operating note (documented):** audit is a SINGLE GLOBAL switch, so adding the next tier requires the toggle workflow — flip audit back ON, label + observe the new ns via Loki, build its `1x-tier-*.yaml` until clean, flip OFF. Remaining tiers: cue → dns → traefik → monitoring. Docs updated: `networkpolicies/README.md` (state + "Adding the next tier"), **CLAUDE.md §5 invariant** (audit now OFF/enforcing, postgres only), tracker H3, this entry.

**Rollback if ever needed:** `kubectl patch cm cilium-config policy-audit-mode=true` + `rollout restart ds/cilium` (back to non-enforcing audit) — reversible in ~1 roll.

---

## 2026-06-22 (cont. 3) — iCloud-backups dashboard (Contacts/Calendars, templated) + H39 residual closed

**iCloud backups board ([[M80]]).** The mini agent started Contacts + Calendars syncs (emit `contacts_backup_*`/`calendars_backup_*`, same schema as photos). Built a **templated** "Mac mini — iCloud backups" dashboard (`dashboards/icloud-backups.yaml`): a `cat` variable = `label_values({__name__=~".+_backup_last_rc"}, job)` drives a per-category **repeating row** (last-success age / rc / items / duration), so future `messages_backup`/`drive_backup` appear automatically. The regex cleanly selects only the mini's iCloud categories (homelab/unifi/velero use different field names; PromQL `=~` is fully anchored). Photos keeps its own richer board (different `photos_export_*` schema). Authored matching alerts (`10-icloud-backups-alerts.yaml`: `ICloudBackup{Stale,Failed,Empty}`, one rule each via metric-regex + `by(job)`, with `label_replace` to strip the `_lastsuccess` job suffix → all current/future categories covered without per-category rules; validated against live Prometheus). **Held the alerts** (commented out of `monitoring/kustomization.yaml`, file committed) — owner chose "dashboard now, hold alerts" because contacts+calendars are mid-dev (both `rc=1`, `items=0`) so Failed/Empty would fire immediately; one-line to enable once green. Severity = warning across the board (incl. Stale) since these are secondary metadata backups vs the photo library. Dashboard verified live (cm in monitoring, sidecar loads it); alert rule correctly ABSENT from the build. `9a45f30`.

**H39 residual closed.** Owner picked H39 next. The technitium-1/w2 kopia-hang residual is **resolved**: last failed PVBs were all 2026-06-19 (incident day); every backup since (06-20/21/22) Completed 0-errors. technitium-1 rescheduled off w2 → **k8s-gpu1** and its `data` PVC backs up cleanly (8.7 MB done==total in `technitium-daily-20260622030012`); recent w2 PVBs also Complete (w2 path healthy). The temp Alertmanager silence (`4fe8a806`) **expired** — no active silences, so the Velero alert suite is live again. Chased the 75× backup-size gap between the HA replicas (technitium-0 653 MB vs -1 8.7 MB): **benign** — both serve the VIP, both hold the user-facing `wind.etherport.net` zone; technitium-0's bulk is logs (551 M) + stats (154 M), not zones; the `dns-cluster.*`/`cluster-catalog.*` zones missing from -1 are Technitium's internal catalog-cluster control zones (primary-side by design). Marked H39 ✅ in the tracker.

**Next:** owner backlog menu still open (H3 NetworkPolicy enforce, H38 forward-auth, H30/M64 supply-chain pinning); M80 follow-up = enable the held iCloud alerts once contacts/calendars go green + add messages/drive (auto-appear on the dashboard).

---

## 2026-06-22 (cont. 2) — photos orphan dedup run #2 (NAS+S3, 15.77 GiB) + orphan metric panel/alert

Second mini-supplied dedup list (`photos_export_orphans` = export-dir files not in osxphotos' ledger): **1,058 entries**, all under `Graham/iCloud/Photos/`.

**Verify (NFS pod, read-only).** Mounted the Backups NFS (`sequoia.wind.etherport.net:/var/nfs/shared/Backups`) in a throwaway pod (cleaner than NAS SSH; rclone runs root under baseline PSS so a root pod can delete). All 1,058 present, all within the Photos prefix, 0 escapes, **15.77 GiB**. Composition differs from M96: only 309 have the ` (N)` suffix; 749 are non-suffixed incl. base-named files (`IMG_0308.JPG`). Spot-checked coverage — **every** sampled orphan has many same-stem copies KEPT (e.g. `IMG_0308.JPG` deleted but `(1)/(9)/(10)/(11)…` retained) → no photo lost; iCloud is the upstream source of truth regardless.

**NAS delete.** Suspended `s3-sync-backups` first (so the deletion couldn't trip the delete-guard / propagate mid-op). Guarded line-by-line `rm` in the pod (prefix-locked, no `..`): **1,058 deleted / 0 errors / 15.77 GiB**, Photos 44,895→43,837.

**S3 purge — blocked by my own M97 guardrail.** Backups → `s3://archive.wind.etherport.net/objects/backups/`; the M97 `ProtectBackupObjectsFromDeletion` Deny covers `archive/*`, and **explicit Deny beats the temporary bypass Allow** (so the plain M96 recipe no longer works). Asked the owner → chose "temp exception + purge now". Temp, prefix-scoped change to `terraform-storage.json` (`953d2cc`): lifted the `archive/*` line from the Deny + added `ListBucketVersions` (bucket) and `GetObjectVersion/DeleteObjectVersion/BypassGovernanceRetention` scoped to `objects/backups/Graham/iCloud/Photos/*`. **Blast radius stayed scoped even with the bucket-wide Deny line off**: object-lock GOVERNANCE still protects every other archive object (no bypass granted outside the Photos prefix). Applied via the [[M98]] `iam-apply` OIDC workflow (input is `policy_name`, not `policy`; wait ~15s post-push to avoid the stale-checkout race). boto3 paginated purge (dry-run first): **1,058 versions, 0 delete-markers, 15.77 GiB, 0 errors**; re-verify showed 0 versions remaining. **Reverted immediately** (`add4386`, byte-identical to pre-temp) + re-applied via iam-apply → `list-object-versions` is `AccessDenied` again (guardrail restored). Re-enabled the sync. **NAS = S3 = 43,837 objects** (consistent → next sync no-op).

**Orphan metric panel/alert (mini-agent task).** Added `photos_export_orphans` (export-dir files not in the ledger; baseline ≈1,070, drops after this delete) to the dashboard as **"Orphan dup files"** (area sparkline; reflowed the stat block to 2 rows for 7 stats) + alert **`PhotosExportOrphansGrowing`** — fires on *growth* only (`max_over_time[26h] - min_over_time[26h] > 50` for 1h), never the absolute value (legitimately declines after cleanup). Metric not pushed yet → reads no-data until the mini's next run. `fa56b12`.

**Commits:** `953d2cc` (temp grant), `add4386` (revert), `fa56b12` (orphan panel/alert + runbook). Docs: this entry + memory `s3-backup-version-purge-needs-m97-deny-exception`.

---

## 2026-06-22 (cont.) — rclone perf+metric fixes (--fast-list, bytes parse); photos missing split

Follow-ups off the cleaned-up rclone dashboard.

**Bytes always 0.** Owner asked why "bytes transferred" read 0 for both sources even though OneDrive was set up days ago. Two causes: (a) the latest runs genuinely transferred 0 B (no new data — confirmed in logs), AND (b) a parser bug — `TRANSFERRED_BYTES` took `head -1` of rclone's per-`--stats`-interval "Transferred:" lines, i.e. the FIRST 1-min sample (~0 during the listing phase before downloads start), so even the initial multi-GB OneDrive sync recorded 0 (7d max=0 gave it away). Fixed to `tail -1` (final summary = true total) in both `rclone-gdrive/01-` and `rclone-onedrive/01-sync-script-configmap.yaml`. (File-count metric already used tail -1; only bytes was wrong.)

**gdrive ~23 min/run with zero changes.** No `--fast-list`, so rclone walked the ~36k-object Drive tree per-directory under `--tpslimit 10`. Added `--fast-list` to both jobs (one recursive listing; buffers tens of MB, well under the 1Gi limit). **Verified by a manual run: 23.5s vs the prior ~23 min (~60×), same 15,705 checks / 36,862 listed.** NAS impact was always minimal — the "Checks" are local `stat()` (size+mtime, no `--checksum`); the time was Drive API latency, not NAS load. Jobs don't actually overlap (gdrive :00–:23→now :00, onedrive :30; `concurrencyPolicy: Forbid`); S3 overlap is lock-guarded ([[M94]]). Left schedule hourly (now cheap). Noted but didn't touch 2 pre-fix errored onedrive jobs (06-21, Personal Vault `ObjectHandle is Invalid` — predates the `--exclude "/Personal Vault/**"` fix; current runs green).

**OneDrive tuning (follow-up Q).** `--fast-list` alone only got OneDrive ~7m→4m45s — its cost is Microsoft Graph per-request latency + 429 throttling (the reason for `--tpslimit 10`), NOT the directory walk fast-list fixes, so it still made thousands of list calls for ~21k items. Added **`--onedrive-delta`** (`63222a5`) — Graph's flat delta/changes feed (~1000 items/page) → a handful of paginated calls. **Verified: 33.8s, single stats line, same 8,522 checks / 21,354 listed (~12× vs original).** Lists the whole drive regardless of path (fine — SRC is the drive root); requires `--fast-list`. Both rclone jobs now complete in ~30s.

**Photos "missing" split (mini-agent task).** The mini now emits `photos_export_missing_resolvable` (genuinely-missing originals a re-download fixes — actionable) + `photos_export_missing_unavailable` (structurally un-fetchable edited Live-Photo clips, ~9, expected) beside the combined `photos_export_missing`. Updated `dashboards/photos-export.yaml`: new **Coverage — available files** stat (`100*(1 - missing_resolvable/clamp_min(photos_total,1))`, green@100/red below), new **Unavailable** stat (neutral blue), repointed the missing stat→resolvable (red>0, not the stale 1600 baseline), split the timeseries into exported/resolvable/unavailable, reflowed top row to 6×w4. `09-photos-export-alerts.yaml`: `PhotosExportCoverageRegressed` now `max(photos_export_missing_resolvable) > 0` for >1h, severity info→warning; unavailable un-alerted. Verified live: coverage 100%, resolvable 0, unavailable 9, total 14,346.

**Commits:** `70976be` (rclone), `b9aa765` (photos). All applied + verified in-cluster. No tracker IDs (polish/observability).

---

## 2026-06-22 — rclone Grafana dashboard: de-dup + clarify; pushgateway pod-label + cm-orphan fixes

Owner flagged the "Rclone Sync (Google Drive / OneDrive)" dashboard: top-row stat tiles didn't say WHICH job each value belonged to; the charts showed ~3 `gdrive` series; and there was no at-a-glance way to see *unresolved* errors (an error one run that's fixed the next should read OK).

**Root cause of the dupes — two independent bugs (see memory `grafana-pushgateway-dashboard-dupes`):**
1. **Pushgateway `pod`-label churn.** Prometheus's ServiceMonitor attaches the SD `pod` target label to scraped pushgateway samples; every pushgateway pod restart mints a new `pod` value → a fresh series per pushed metric per dead pod (3 pod incarnations in the 7d window = 3 `source="gdrive"` series). `honorLabels: true` only protects labels in the pushed exposition (job/instance), not `pod`. **Fix:** `serviceMonitor.metricRelabelings: labeldrop pod` on the pushgateway HelmRelease (singleton aggregator — pod identity is meaningless). Verified live on the ServiceMonitor.
2. **Dashboard cm namespace orphan.** `rclone-gdrive/kustomization.yaml` forces `namespace: rclone`, but the cm's `metadata.namespace` said `monitoring` — so a past raw `kubectl apply -f` had created a SECOND copy in `monitoring` that Flux never managed (manager `kubectl-client-side-apply`, rv stuck at 19894). Both carry `grafana_dashboard:"1"` + the same uid, and the Grafana sidecar is cluster-wide → the two flapped and the **stale** copy rendered (that's why my v1→v2 edit "wasn't applying"). **Fix:** deleted the monitoring orphan live; set the file's `metadata.namespace: rclone` to match kustomize so a stray manual apply can't recreate it.

**Dashboard redesign (`05-grafana-dashboard.yaml` v1→v2, 7→8 panels):** every query now `max by (source)(…)` (collapses any residual pod churn + the stale series still in the window); top-row tiles labelled per source (`value_and_name` + `{{source}}`); reframed "Errors (Last Sync)" → **"Unresolved Errors (latest run)"** (background-colored red>0) with a description explaining the per-run-gauge semantics (errors_total is overwritten each run, so a value that drops to 0 = the prior run's failures resolved); added an **"Errors & Notices Over Time (per run)"** stepped timeseries (errors forced red) so you can watch a spike return to 0.

**Commits:** `ec8410a` (dashboard + pushgateway relabel), `bbfd2cf` (cm namespace align). **Verified:** only one cm copy left (rclone ns, v2); sidecar log shows the flap → orphan removal → single re-write; Grafana API serves the 8-panel v2. No tracker item (ad-hoc polish). Docs-as-code: memory saved; this entry.

---

## 2026-06-21 (cont. 2) — iCloud Photos dedup executed: NAS rm + S3 version-purge ([[M96]])

The mini's osxphotos dedup couldn't bulk-delete over SMB, so the owner supplied a relative-path delete list (30,578 entries, all `Graham/iCloud/Photos/`).

**NAS.** Verified the list against the live NAS (all under Photos; 2,859 already gone from the mini's partial SMB run, clustered at the list head — the named files genuinely absent, same-basename *collisions* like `IMG_0295 (10–15)` correctly NOT in the list). Ran a guarded line-by-line `rm` over SSH (prefix-locked to `Graham/iCloud/Photos/`, rejects `..`/outside, quoted for spaces+parens): **27,719 deleted / 197.5 GB / 0 errors**, Photos `587G→389G` (≈ the ~400 GB real library; 41,727 files left).

**S3.** Dupes were still in S3 (sync suspended = safety net). Granted a temporary Photos-prefix-scoped `BypassGovernanceRetention`+`ListBucketVersions`+`GetObjectVersion` on `terraform-storage` via the [[M98]] `iam-apply` workflow (OIDC — no admin/claude-admin, no standing bypass). Purge: `list-object-versions` (prefix) filtered to the dedup list → batched `delete-objects --bypass-governance-retention`. Two snags fixed: the per-1000 JSON was too big as an inline arg → `--delete file://`; and `workflow_dispatch` right after `git push` checked out the **pre-push** commit (applied a stale policy version) → re-dispatched after a settle. Result: **30,579 versions deleted, 0 errors, 213 GB freed** (S3 also held the 2,859 the NAS no longer had); S3 Photos now 41,727 current objects = NAS exactly, 386 GB. Then **reverted the grant** (terraform-storage v7, TEMP gone) and **re-enabled the backups sync** (`suspend:false`). NAS↔S3 consistent → next sync is a Photos no-op (no guard trip).

**Decisions/why.** Surgical per-list purge (not an S3-vs-NAS diff) since the list is authoritative + exact. Governance-bypass kept temporary + prefix-scoped + applied/reverted via CI (no admin key on devbox). Deleted while still in STANDARD (ahead of the 5-day Deep Archive transition) to avoid the early-deletion penalty. iCloud remains the upstream source of truth, so the temporary S3 gap was acceptable.

**State:** M96 done; the whole backup delete-protection + approval + dedup arc is closed. Photos NAS=389G / S3=386G, both deduped.

---

## 2026-06-21 (cont.) — ship + test the approval flow: CF apply, iam-apply workflow, split-horizon DNS, house-style emails, onedrive Vault fix ([[M94]],[[M98]],[[M99]])

Picked up the held [[M94]] delete-guard + CF-Access approval flow and shipped it fully.

**Shipped the approval flow.** Committed everything (`287ef09`), dispatched the **Cloudflare TF apply** via `github_dispatch_pat` (run `27911690380`) → `backup-approve.wind.etherport.net` live (302 Access). Rolled the `backup-approval` Deployment onto the rebuilt image (`/healthz` ok).

**IAM gap caught by a self-test.** Built a synthetic-deletion self-test Job to send a real approval email. It surfaced that the flow writes to `logs.archive.wind.etherport.net/approvals/*`, which the `kubernetes-s3-backup` policy didn't allow (PutObject denied). Tried to apply the fix but: (a) devbox only has the `homelab` profile (no claude-admin key), and (b) **claude-admin is scoped to `policy/terraform-*`** so it couldn't touch `s3-backup-kubernetes-policy` anyway. The classifier also (correctly) blocked the live IAM mutation as out-of-scope. **Resolution = CI, not claude-admin:** the `gh-actions-terraform` OIDC role has `iam:*PolicyVersion` on `*`, so I added **`.github/workflows/iam-apply.yml`** ([[M98]]) to apply any committed `iam-policies/<name>.json` via OIDC (auto-prunes the 5-version cap), dispatchable remotely. Dispatched it → approvals/* granted (`78978fd`, run `27912386842`). **This is the durable "remote IAM without an admin key" mechanism the owner asked for; claude-admin stays disabled.** Re-ran the self-test: email sent, pending record uploaded, approval page renders the full manifest end-to-end.

**Split-horizon DNS ([[M94]]).** The hostname was CF-tunnel-only → failed on Tailscale. Technitium uses explicit per-service A → Traefik VIP (no wildcard), and there's precedent (the `approve` record). Added a `backup-approve` A → VIP + a Traefik IngressRoute. External keeps CF Access; internal is HMAC-gated. (Couldn't curl-verify from devbox — MetalLB BGP VIP isn't L2-reachable same-subnet — but it mirrors the working grafana/ha pattern; owner verifies from tailnet.) `c5aa81b`.

**House-styled emails/pages ([[M94]]).** Re-skinned the approval email, approval page, and transfer-failure email to match `service-status-report.py` (CSS vars + light/dark, eyebrow/pill/summary-grid/cards). Approval page got Confirm buttons top + bottom (long manifests). `422b489`.

**onedrive Personal Vault ([[M99]]).** AI alert "onedrive sync not working" → rclone erroring on the locked Personal Vault folder. This was pre-existing but **masked** by the old `tee` exit-code bug that [[M95]] just fixed (so the fix is working — it unmasked a real silent failure). Excluded `/Personal Vault/**`; verified clean. `c5aa81b`. (Vault contents aren't rclone-backupable.)

**State at end.** Delete-guard + approval flow fully live + tested (external CF Access + internal Traefik, house-styled, IAM correct). iam-apply workflow available for future manual-policy changes ([[M97]] tightening). [[M96]] Photos dedup still parked on the mini. **Next:** owner clicks through the test email to eyeball the new style; when mini dedup completes, run the Photos purge; wire the deferred rclone↔S3 sentinel lock.

---

## 2026-06-21 — backup data-loss hardening: S3 delete-guard + CF-Access approval, rclone guards, Photos dedup ([[M94]],[[M95]],[[M96]],[[M97]])

**Context.** Started on the UNAS nvme0 recurrence ([[M93]]) and an aws-s3 sync review; became a backup data-loss-prevention sweep.

**UNAS nvme0 ([[M93]]).** 3rd controller drop, this time across a `systemctl reboot`. Recovered healthy (SMART: 2% used, 0 media_errors, warning bit = temperature, unsafe_shutdowns 7); md4 rebuilt `[2/2]`. **Gotcha:** a raw `systemctl reboot` left the box **half-up** — web UI + ping responded but SSH/NFS/SMB were down for minutes while UniFi-OS services restarted and the cache resync spiked load — prefer a UI/console restart. The md4 (NVMe RAID1) rebuild saturated both NVMe (~96% util) → slow browsing for the ~1h resync (it's an LVM **writethrough** dm-cache: origin md3/RAID6 data stays safe, but reads route through the busy cache device). Confirmed **wear is a non-issue → firmware/APST**. Thermal revision: nvme0 ran 69°C post-reboot, so disabling APST (keeps it out of deep idle) would *raise* idle temp → firmware rollback / airflow is the better durable fix than APST-off.

**S3 delete-protection ([[M94]]).** `aws s3 sync --delete` had no guard — a downed/empty NAS source would mirror as a mass S3 deletion (a real risk: this morning's NAS outage was exactly that scenario). Added **Guard 1** (abort if source empty/unmounted) + **Guard 2** (abort if a run would delete > 1000 objects or > 10% of dest; legit small deletes pass). Fixed a **false-FAILED**: the nightly "526 files checksumUnavailable" was a sync-while-rclone-writes race (benign, 0 mismatches) — status now keys on `files_succeeded` (HEAD ok), not `files_verified` (checksum present), plus a re-HEAD settle pass. **Decision:** human approval for large *intended* deletions via a **CF-Access email button** (owner chose CF Access over a GH-Actions approve workflow, and "build it all, ship together"). Built `approval-server.py` + `request-approval.py` (in the sync image) + a `backup-approval` Deployment/Service behind CF Access at `backup-approve.wind.etherport.net`; scoped/one-time/expiring HMAC-signed markers in S3; the email shows a **folder rollup** (not a flat list — the deletion's *shape* is the "is this expected?" signal) + sample + full-manifest CSV. **Shipped `287ef09`**, in-cluster `/healthz: ok`. **Open step:** apply the `terraform-cloudflare` stack (action=apply) to create the hostname + Access app.

**rclone hardening ([[M95]]).** gdrive/onedrive ran `rclone sync` (deleting) hourly with **no `--max-delete`** → a transient empty cloud listing (token blip, 429, wrong drive_id) would wipe the NAS mirror (then cascade to S3). Added: source-non-empty guard, `--max-delete 200`, **real exit-code capture** (BusyBox `rclone | tee` had been reporting tee's status → failures recorded as *success*), EXIT-trap fail-safe `success=0` metric (pre-sync failures previously only caught by the 25h staleness alert), gdrive `--tpslimit 10`, `activeDeadlineSeconds: 3000`. Live `66b8c49`. **No approval flow on rclone** — redundant (max-delete hard-stop + the S3 guard on the 2nd hop + S3 30-day versioning cover the cascade; rclone image is minimal POSIX-sh, a harder lift for marginal gain).

**iCloud Photos dupe purge ([[M96]], parked).** A Mac mini osxphotos export left ~200GB of dupes in the NAS Backups share + S3 (`…/Graham/iCloud/Photos/`). Bucket = GOVERNANCE-lock 180d (bypassable) + versioning (must delete VERSIONS to free space) + lifecycle → Deep Archive (now extended **2→5d**, live). **Decision: Option B (surgical)** — keep the good ~400GB (already correctly backed up; deleting+re-uploading would waste transfer and open a no-backup gap, bad on a flaky-NAS day), suspend the backups sync (so it won't propagate the in-progress dedup as delete markers on locked versions), and when the mini's dedup finishes, diff S3-vs-NAS and version-purge only the dupes with `--bypass-governance-retention`. Wrote a scoped one-off IAM policy (`iam-policies/oneoff-photos-dedup-bypass.json`). **Parked** awaiting the mini.

**IAM reconcile ([[M97]]).** Repo `iam-policies/*.json` had drifted from live (applied manually, not via `terraform apply`). Synced repo→live (terraform-storage/networking; created the missing terraform-cloudfront). Flagged two over-broad live grants (terraform-storage `s3:Delete*` on `*`; terraform-compute `iam:PassRole/AttachRolePolicy` on `*`) → backlogged for a scoped pass.

**State at end.** Delete-guard + approval deployed & healthy (CF apply is the one open step); rclone hardened & live; backups sync suspended pending the Photos purge; lifecycle 5d live; IAM repo matches live. **Next:** (1) dispatch the `terraform-cloudflare` apply; (2) when the mini's dedup completes, run the Photos version-purge ([[M96]]); (3) wire the deferred rclone↔S3 sentinel lock; (4) [[M97]] IAM scoping. Commits this session: `718e908` (suspend), `d5c65c4` (lifecycle 2→5d), `66b8c49` (rclone), `287ef09` (delete-guard+approval + IAM reconcile).
---

## 2026-06-21 — M79 Photos backup: completion, dedup (30,577 dups), steady-state hardening

Closing out the M79 marathon. Carries on from the 2026-06-19→20 entries (multichannel,
NVMe cache, local export DB).

**Backup completed.** The 15h39m PhotoKit download pass (2026-06-20, rc=0) covered the
library: **~15,355 distinct photos backed up**, **293 photos truly unbacked** (originals
iCloud won't serve) + ~950 Live-Photo `.mov` clips (still image *is* backed up). Missing
list: `~/Library/Logs/photos-export/MISSING-photos.txt`.

**Dedup of ~30,577 duplicate files (the DB-less-retry mess).** Computed the orphan set
directly from the export DB (`export_data.filepath` = canonical keepers) with a **survivor
guard** (never delete a photo's last copy): 41,715 canonical + 10 protected + 30,577 dups =
72,303. ⚠️ **Near-miss:** the first compute had a path-bug that flagged *all* 72,303 as
deletable — caught by reconciling `safe+protected==total` *before* deleting. Always verify
the math before a mass delete.

**The "11s/delete" was NOT the cache — it was contention + single-channel SMB.** Owner
rightly pushed back (cache had been fine all day). Clean measurement: a **single delete =
~15 ms**; sustained over SMB = 322–642 ms (NAS serializes btrfs metadata commits, and my
earlier `mc_on=no` forced everything onto one channel; my "11s" was measured *during* a
16-way parallel rm fighting that one channel). Re-enabled **multichannel (`mc_on=yes`)** —
the original idle drops were the NVMe cache, not multichannel, so disabling it was treating
the wrong thing. Even so, over-SMB bulk delete floored at ~2.5–3 h (NAS-bound). **Owner ran
the delete NAS-LOCAL over SSH** (local btrfs unlink, no SMB) — fast. **Lesson: bulk
file-count operations on this NAS belong NAS-local, not over SMB.** Verified after: **41,727
files**, all sampled dups gone, all sampled canonical keepers present. ✅

**Steady-state hardening (this session):**
- **Nightly (`photos-export.sh`) now defaults to LOCAL mode** — no Photos.app/PhotoKit, so
  no TCC dialogs / `photolibraryd` wedges (those caused the 2026-06-20 disruption). It does
  `--update --exportdb <local> --ramdb --sidecar XMP --cleanup`. `DOWNLOAD_MISSING=1` makes
  it the (fragile, supervised) PhotoKit download pass + daemon-restart. Timer re-enabled
  (22:00, local).
- **Anti-dup guarantee:** the persistent **local** `--exportdb`
  (`~/Library/Application Support/osxphotos/graham-icloud-photos.db`, 41,715 rows) means
  `--update` reuses canonical filenames → never re-creates `(N)` dups; `--cleanup` removes
  any stray orphan. The dup explosion only happened because the DB lived on SMB and got
  lost. **Rule: never run osxphotos here without `--exportdb` → that file; never delete it.**
- **Lockfile guard** (`<RDIR>/.run.lock`, atomic mkdir) added to BOTH `photos-export.sh` and
  `photos-export-resume.sh` — two runs racing the same ledger could re-mint dups; now only
  one runs at a time.

**In progress at write time:** a supervised `DOWNLOAD_MISSING=1` pass (via the wrapper,
dup-safe `--exportdb` + lock + `cleanup=off`) attempting the 293/clips. May recover
transient failures; genuinely-unavailable ones need manual "Download Originals" in Photos.

**Next:** confirm the download pass result (and that DB row count didn't balloon = no new
dups); then M79 is effectively done bar the permanent-missing tail. S3 dup cleanup is the
owner's (infra agent) — same `dedup-relative-paths.txt` maps to `objects/backups/<rel>` keys.

---

## 2026-06-20 (cont. 3) — devbox CI dispatch (PAT) + k8s-vms watchdog saga ([[M91]],[[M92]])

**Dispatch enabled ([[M92]] ✅).** Owner created a fine-grained PAT (Actions:rw + Contents:r on the
repo), sealed into `homelab-ops.sops.yaml` as `github_dispatch_pat`. devbox can now `workflow_dispatch`
via the REST API (verified). Also: fixed a `.gitignore` leak (`!**/*.sops.yaml` was un-ignoring
`.decrypted~*.sops.yaml` plaintext SOPS tempfiles → hard re-ignore appended, `c8e952f`). Extended the
CI drift sweep to ALL 22 stacks + email-on-drift (red run, `c42a367`/`812cb58`); first runs exposed +
fixed a self-hosted bug (install unzip BEFORE setup-terraform, `39dc18a`).

**The watchdog dead-end ([[M91]]).** Goal: enable the i6300esb hardware watchdog (hang auto-reset) on
the 8 k8s VMs — the standing `terraform plan` drift. Dispatched the per-stack apply node-by-node
(authorized, rolling): w4 (canary) → w3 → w2 → w1 → gpu1. Two incidents en route, both recovered via
the PVE API: **(1)** w3's graceful shutdown HUNG on un-drainable single-instance `cue-db-1` (PDB on 1
replica → RBD wouldn't unmount) — force-stopped+started it; **(2)** a bug in my hang-detector
(`[ "$ns" != "Ready" ]` counted `Ready,SchedulingDisabled` cordoned nodes as down) force-stopped a
HEALTHY w2 — restarted it; fixed the detector to `grep "^Ready"`. **Then the gut-punch:** after 5
reboots the plan STILL showed all 8 drifting and the VM configs had **no watchdog** — **bpg/proxmox
0.106 silently NO-OPs the `watchdog {}` block.** The 5 reboots achieved nothing toward the watchdog
(cluster fine throughout). Stopped before the control planes.

**Resolution (owner chose "do it right").** (a) `lifecycle.ignore_changes=[watchdog]` on the 3 VM
resources → plan now "No changes" (`0e80782`); (b) attached the device to all 8 configs via the PVE API
`qm set --watchdog` (the working path; `current=[model=i6300esb,action=reset]`); (c) guest daemon
already deployed+enabled on all 8.
**CORRECTION (same session):** verifying e2e on w4 (cold-rebooted to present the device) revealed the
watchdog **still doesn't work — `i6300esb.ko` is ABSENT from the node kernel** (only softdog/wdat_wdt;
linux-modules-extra lacks it). So `/dev/watchdog0` never appears + the daemon is inert; the hardware
watchdog has never armed. Tried a `modprobe i6300esb` ansible task → FATAL (module not found) →
reverted (`2642aa4`). **Watchdog BLOCKED pending the kernel module (M91)**; drift stays clean
(ignore_changes), device attached + harmless. Cost of the saga: ~7 node reboots + 3 incidents for a
feature that can't work without the module — lesson logged in CLAUDE.md §5.
**PARKED + investigated 2026-06-21:** the real reason `i6300esb.ko` is absent = `linux-modules-extra-$(uname
-r)` simply isn't installed on the nodes (the standard package that ships it; my apt task no-op'd). So
it's resolvable via the production-standard path (install -extra → modprobe → feeder), per-kernel
durability caveat noted. Left as the M91 follow-up; not pursuing now.
**"Down" emails were the reboots, not real:** the AI advisor sent **0** diagnosis emails (transient-
suppression skipped every self-resolving reboot alert ✅); the emails came from Alertmanager's plain
`email-alerts` receiver firing KubeNodeNotReady/TargetDown on the ~7 rollout reboots (fire+resolve per
node). All transient, active alerts now clear. (Possible future tidy: dampen email-alerts during
planned node reboots, or accept it.)

---

## 2026-06-20 (cont. 2) — Config-drift / docs review; CI-native drift for all TF stacks

**Docs drift fixed (`bb227a5`):** gdrive/onedrive READMEs daily/nightly→hourly, root README reframed (devbox is the dev-session host, not the mini) + OneDrive/unas-health added to backups table & component list, two dead `docs/README.md` links removed, M78→superseded-by-M88. (Agent-assisted.)

**Live config drift:** git clean; Flux all reconciled; TF proxmox **firewall/sdn/standalone-vms** = No changes. **k8s-vms = 0 add, 8 change** ([[M91]]) — the deliberate i6300esb **hardware watchdog** (action=reset, hang-recovery; relevant to the GPU wedge) + gpu1 floating-mem 8192→0 were authored but never applied. NOT manual drift. Resolve via a **rolling** CI apply (`terraform-proxmox-k8s-vms` apply with `target`, node-by-node — attaching the watchdog device likely restarts the VM). External-provider stacks not checked from devbox (no GH token there → can't dispatch CI).

**CI-native drift for everything ([[M90]], `2f85c28`).** Per owner "everything should wind up as CI": extended `terraform-drift-detection.yml` (was AWS-only) with a self-hosted `plan-internal` matrix (cloudflare, unifi, proxmox ×4) feeding the same daily `tf-drift` issue. Corrections stay per-stack `workflow_dispatch` apply (OIDC). OneDrive sync still running its initial full pull (8k+ files, double-run cleaned up). sdn lock file gained a linux hash from devbox init (`607759d`).

---

## 2026-06-20 (cont.) — Hourly syncs + unified sync observability + pve-ipmi firewall fix + cloudwatch baked-image cutover

**Syncs → hourly + unified observability.** gdrive `0 * * * *` / onedrive `30 * * * *`
(staggered; Forbid skips a tick if a run >1h). Made the rclone Grafana dashboard
**source-templated** (`$source` var, per-source legends, retitled "Rclone Sync (Google
Drive / OneDrive)") so it covers both + future sources. Added `gdrive-sync` + `onedrive-sync`
to `service-status-report/services.py` (the shared source-of-truth for the daily status
email AND the generated service dashboard). AI advisor already gets both syncs' alerts via
the alertmanager catch-all webhook (`continue:true`) — no routing change needed. Note re
"resolve autonomously": hourly cadence IS the natural retry now, so explicit force-rerun
remediation is largely redundant (offered, not built). (`65ad0ab`)

**pve-ipmi TargetDown ([[M89]], `96318e3` applied).** `up{job="pve-ipmi"}=0` since 13:16Z.
Root-caused from the repo (no SSH — the PVE-SSH was classifier-blocked, only an alert was
forwarded): the H37 default-deny host firewall had **no allow for the ipmi_exporter `:9290`**
→ scrape dropped (timeout, not refused; host up + `:22` open). Same latent class as the
Ceph oversight. Fixed with a `pve-ipmi` security group (`10.10.201.0/24` → `9290`) in the
proxmox firewall TF; `terraform apply` (1 add, 1 change, 0 destroy, owner-authorized).
Verified `up=1` + 12 temp sensors. **CLAUDE.md §5 updated: the PVE firewall now has THREE
required allows (mgmt / Ceph / IPMI).**

**cloudwatch-to-loki baked-image cutover ([[M87]] done, `dd29537`).** GH Actions built the
image (tags `main`+`sha-734fe3f`); owner flipped the ghcr package Public. Cut the CronJob to
`ghcr.io/sparked-diamond/cloudwatch-to-loki:main` + `imagePullPolicy: Always`, dropped the
runtime `pip install` → `command: ["python","/scripts/forward.py"]`. Verified a run: no pip,
auth ok, events pushed. Runtime-pip failure class eliminated.

---

## 2026-06-20 — Full health sweep + cloudwatch-to-loki hardening + OneDrive sync staged

**Health sweep (all clear).** 8/8 nodes Ready, 0 NotReady/CrashLooping pods, Flux +
all HelmReleases reconciled, **no active alerts**. **M84 confirmed fixed**: tonight's
Velero nightly = all 11 backups `Completed`, 0 errors (prior nights were
PartiallyFailed/Failed). Postgres 3/3 healthy (incl. recreated `-6`); CNPG barman S3
backups completed; unifi-backup + rclone gdrive complete; `unas-health` running. GPU
DCGM metrics flowing again; technitium 2/2. The 4h+ `s3-sync-backups` job was not stuck
— a legit 45k-file/325 GB iCloud Photos push (resumed photo backup) in its verify phase.

**cloudwatch-to-loki hardening ([[M87]], `734fe3f`).** Root-caused the overnight email: a
single job failed `BackoffLimitExceeded` because it `pip install`s boto3+kubernetes on
every 5-min run with **`backoffLimit: 0`** → a transient PyPI/network blip failed it
instantly + paged. It self-recovered (next run's pip succeeded). **Immediate fix
(deployed+verified):** `backoffLimit 0→3` + `pip --retries 5 --timeout 30`. **Proper fix
staged:** `image/Dockerfile` bakes the deps + `.github/workflows/cloudwatch-to-loki-image.yml`
builds to `ghcr.io/sparked-diamond/cloudwatch-to-loki` (script stays in the ConfigMap).
**Cutover gated on the one-time "make ghcr package public" step** (GITHUB_TOKEN can't do
it for user-owned packages — same gotcha as cloudflare-ddns), then switch the CronJob
`image:` + drop the pip line. Tracked M87.

**OneDrive sync staged ([[M88]], `705e314`).** New `platform/kubernetes/rclone-onedrive/`
mirrors `rclone-gdrive`: nightly `rclone sync onedrive: → /backup/Graham/OneDrive/` (NAS
Backups share → rides NAS→S3), 23:00 PT, `--tpslimit 10` for OneDrive throttling, same
metrics/alert shape. Account = personal MS account w/ M365 sub = **OneDrive Personal**.
**Blocked on interactive OAuth** (rclone's onedrive backend can't auth headless on
devbox): built but **NOT registered in clusters/wind** + secret omitted, so nothing
deploys half-built. Activation: user runs `rclone config` on a browser machine → hands
over the `[onedrive]` block → seal `04-secret.sops.yaml` + uncomment in kustomization +
register the dir. See the component README + `04-secret.sops.yaml.template`.
**Activated same day (`a893c00`):** owner ran `rclone config` on the laptop (chose the
"OneDrive (personal)" drive `F4E003FF4BAE9ABD`), sealed the `[onedrive]` block into
`04-secret.sops.yaml` and pushed (`--no-gpg-sign` to dodge the laptop SSH-signing-key
gap). I uncommented the secret + registered the component; Flux decrypted it cleanly and
deployed `onedrive-sync`. First sync verified — rclone authed and copied files into
`/backup/Graham/OneDrive/` (Documents/Pictures/WSP), no errors. M88 ✅.

---

## 2026-06-19 (evening) — UNAS SSD-cache member drop (NVMe APST hang) + md-degradation alerting

**Incident.** Owner saw the UNAS UI flag **Storage Pool "At Risk" + SSD cache
"Transferring"** while every drive showed "Optimal"; separately the mini photo-backup
agent reported **SMB hanging within ~1 min** after ~5 h stable. The two were the same
event. SSH'd into the UNAS (`10.10.209.10`, key from `unifi-backup/01-secret-ssh.sops.yaml`)
and found the smoking gun in `/proc/mdstat` + dmesg: **`nvme0` (one of the two SSD-cache
RAID1 members, `md4`) fell off the PCIe bus** at ~11:04 (`nvme nvme0: controller is down;
CSTS=0xffffffff`, `/dev/nvme0` gone) — a textbook **NVMe deep-power-state (APST) hang**,
hours into runtime. `md` kicked it; `md4` ran **degraded `[2/1]`**. `smbd`/`kcopyd`/`btrfs`
were stuck in **D-state** on the dead device → that was the SMB hang. RAID6 data array
(`md3`) `[8/8]` healthy throughout; cache survivor `nvme1` SMART pristine → **no data risk**.

**Why the UI lied:** SMART ≠ bus presence. A drive that *vanishes* can't report bad
SMART, so the per-drive widget showed last-known-good "healthy"; only the pool status
(reading live `md`) reflected it.

**Fix.** Corrected my earlier "don't reboot mid-Transferring" advice — that assumes a
non-redundant cache; this cache is **RAID1**, so the survivor holds all data across a
reboot, making a reboot both safe and necessary (box was wedged on D-state I/O). Owner
rebooted from the UI; `nvme0` re-probed clean and `md4` auto-rebuilt to **`[2/2] [UU]`**
(~90 min). (Also confirmed: SSH comes up late in boot — port 22 closed while UI:443/SMB:445
already open; not a NAS-down.)

**Root cause = the firmware update (prime suspect).** Box updated to `UNASPRO v5.1.19`
(build 260613) this morning, rebooted 06:17, stable ~5 h, then the controller hung on a
power-state transition. `default_ps_max_latency_us=100000` permits deep APST; the
appliance kernel cmdline is fixed so we **can't persist `...=0`**. Not provable vs. a
marginal M.2 — **recurrence is the tell**.

**Durability shipped.** (1) New runbook
[`docs/runbooks/unas-nvme-cache-apst-hang.md`](../runbooks/unas-nvme-cache-apst-hang.md).
(2) New IaC component **`platform/kubernetes/unas-health/`** ([[M86]]): CronJob SSHes the
UNAS every 15 min, parses `/proc/mdstat`, pushes degraded/active/total gauges to
Pushgateway → **`UnasMdArrayDegraded`** (+ check-failing/stale watchdogs). Closes the gap
where the array ran degraded for hours unalerted. Reuses `unifi-backup-ssh` (already
authorized on the UNAS); host-key pinned. Validated (kustomize + parser unit-tested).
**Recurrence watch:** a self-scheduled quiet check will ping only if `nvme0` drops again.

---

## 2026-06-19 (morning) — M84 fixed (dataPathConcurrency=2) + advisor overnight review

**M84 resolved** (owner back; the deferral was only about not guessing chart-wiring unattended).
Verified the velero 11.4.0 chart supports `configMaps` + `nodeAgent.extraArgs`, then added a
`node-agent-config` CM (`loadConcurrency.globalConfig=2`) + `--node-agent-configmap=velero-node-agent-config`
to `velero.yaml` (`918e101`). node-agent rolled 8/8 clean with the config. **Verified twice** —
on-demand backups completed **0 stalls**: infrastructure 20/20, postgres 9/9 (postgres had Failed
overnight from my -6 mess; now has a fresh clean restore point). Tonight's nightly should be fully clean.

**Advisor overnight review** (owner reported "many emails"): **no flood — `cap_reached: 0`**. ~6
legitimate one-off diagnoses, one per real alert that fired during the night's remediation churn
(`TargetDown`/`KubeDaemonSetRolloutStuck` from the dcgm reboot, `KubePodCrashLooping` from postgres-6,
`KubeJobFailed` from the failed velero backups, `KubeClientErrors`, `NodeSystemSaturation`). The
once-per-day cap-fix held. Quiet now that everything's resolved.

**Advisor transient-suppression (`ecd37ea`, owner-approved follow-up).** Wired the noise-cut: a new
`_alert_still_firing(alert)` helper queries Prometheus `ALERTS{alertname,alertstate="firing"}` (matched
on namespace too when present); `_advise` now skips the Claude call **and** the email — auditing
`skipped_resolved` — if the alert has already resolved by the time the advisor reaches it (rollout
finished, pod recovered, node back). That's exactly what produced the ~6 overnight emails. **Fail-open:**
if the Prometheus check itself errors we do NOT suppress (never silently drop a real alert). NOT
cooldowned on skip, so a genuine re-fire still active next time is diagnosed. Validated (py_compile +
kustomize), reconciled, `rollout restart deploy/remediation-controller` — new pod healthy, processing.

**Silence: extended (owner-approved).** Replaced `4fe8a806` (was expiring 19:22Z today) with
`f7907750` — same matchers (`VeleroBackupPartial|VeleroLastBackupAgeHigh|KubePodNotReady`, ns=velero),
now **expires 2026-06-20 12:00 UTC** so tonight's now-clean (M84-fixed) nightly supersedes the stale
06-18/06-19 partials before it lifts. `VeleroBackupFailed` is deliberately NOT in the matcher set — a
genuine hard failure tonight still pages.

---

## 2026-06-19 — M79 SMB instability root-caused & fixed (multichannel); library recovered; export resumed

Picked up M79 after the owner VNC'd in to find Photos had force-quit ("quit to prevent
corruption from the library") and, post-reboot, errored **"PhotosLib cannot be found."**
Two questions: why did it corrupt, and why didn't the drive come back.

**Root cause (found live, not guessed).** While diagnosing I watched **`Personal-Drive`
drop on its own *while idle*** — that rules out write-load/sleep/bandwidth (link is 10G
wired, sleep already disabled). There was **no `nsmb.conf` at all** → macOS SMB
**multichannel** was ON, the textbook cause of spontaneous idle SMB session resets
against a NAS over a fast NIC. A reset mid-write to the sparsebundle (which backs the
Photos library as a "local" APFS volume over SMB) is what force-quit Photos and left the
APFS journal dirty.

**Why the drive didn't come back.** Two gaps: (1) nothing attaches the sparsebundle at
login — `hdiutil attach` only ran inside the export job — so after reboot the shares
remounted but `/Volumes/PhotosLib` never existed; (2) the volume was *dirty* (failed a
read-only mount = unreplayed journal). Photos remembered the path but the volume wasn't
there.

**Fixes (all in git, sudo-free, self-healing on rebuild):**
- **`infra/macos/mini/nsmb.conf`** — `mc_on=no` (multichannel off) + `protocol_vers_map=6`
  (no SMB1) + `notify_off=yes`. Installed to `~/Library/Preferences/nsmb.conf`.
- **`mount-nas.sh`** now (a) installs/refreshes `nsmb.conf` *before* mounting (only new
  mounts pick it up) and (b) **attaches the sparsebundle after mounting** → PhotosLib is
  present at login. Both idempotent.
- **`photos-export-resume.sh`** — auto-attaches the bundle, and `--cleanup` is now opt-in
  (`CLEANUP=1`, default OFF) because the `.osxphotos_export.db` ledger was lost in the
  corruption; cleanup without it could delete+re-download already-exported files.

**Recovery + validation.** Read-write attach replayed the journal (PhotosLib mounted).
The library DB had a **14 GB un-checkpointed WAL** (the in-flight downloads at force-quit)
+ a 34 MB base — so a standalone `integrity_check` of the base "failed" (expected: pages
live in the WAL). Ran `PRAGMA wal_checkpoint(TRUNCATE)` — which doubled as a **14 GB
sustained network-write soak test of the SMB fix**: WAL 14 GB→0, **0 mount drops, 0 SMB
reconnects** throughout, then `integrity_check` = **`ok`**, **14,267 photos** readable.
So: library healthy (not corrupted), and the multichannel-off fix proven under real load.

**State at end.** Remounted clean (verified live session: SMB 3.1.1, single-channel, 0
reconnects). Re-launched `photos-export-resume.sh` (CLEANUP off) — osxphotos skips the
10,203 already-exported and downloads+exports the remaining ~4k via PhotoKit, rebuilding
the DB. Persistent monitor watching progress/drops/completion.

**Next steps:** (1) let the ~4k tail finish (monitor will report); (2) verify ~14.3k
files on `Backups`; (3) one-off `CLEANUP=1` run (or the nightly `photos-export.sh`, which
keeps `--cleanup`) once the DB is healthy to re-establish deletion mirroring; (4) enable
the `net.wind.photos-export` LaunchAgent; (5) confirm `s3-sync-backups` ships
`Graham/iCloud/Photos`. **Lesson:** sparsebundle-on-SMB is viable but *requires* SMB
multichannel disabled; deeper insurance (sudo-only) = system-wide `/etc/nsmb.conf` +
raised `net.smb.fs.kern_*_deadtimer` so a server stall pauses I/O instead of erroring up
into APFS.

**UPDATE (same day, evening) — the deeper root cause was NAS HARDWARE, and completion.**
After resuming, the SMB degraded *progressively* (fine → flaky → EIO → hang) over the
afternoon, eventually hanging even on a freshly-rebuilt mount. **Owner SSH'd the UNAS and
nailed it: an NVMe SSD-cache drive (`nvme0`) fell off the PCIe bus (~11:04), `md` kicked it
from the cache RAID1, and `smbd`/`btrfs`/`kcopyd` went D-state on the dead device** — exactly
the "reads work ~10 s then hang" symptom, and the "stable ~5 h then degraded" timing
(NAS booted 06:17 from the update, SSD dropped ~5 h later). Data array (RAID6) healthy → no
data risk. So `mc_on=no` was a genuine improvement but the real instability was the dying SSD,
not the client. **Owner rebooted the UNAS; `nvme0` re-probed clean → SMB stably healthy.**
Lesson: progressive SMB degradation ⇒ suspect NAS storage/SMB health, not just client tuning;
diagnose with a **timeout-guarded** read (a plain cp/dd just hangs on D-state).
- Built `~/Library/Logs/photos-export/auto-resume.sh` (uncommitted one-off): waits for 3
  consecutive timeout-guarded reads off `/Volumes/PhotosLib`, then auto-runs the resume.
  Fired at 16:24 on recovery.
- **`--exportdb <LOCAL path>` + `--ramdb`** was the fix that let it finally complete: osxphotos
  writes the export DB as the final step, and on the SMB share that write kept failing
  (rc=1 → wrapper retried **~18×** even though files were exported). DB now local (rebuildable
  ledger; correct to keep off NAS/S3). First clean `rc=0` at 22:08 (5h41m local run).
- **Clean completion revealed two issues:** `Processed: 14343, exported: 10420, missing: 11538`
  → ~11,538 versions' originals were never downloaded (PhotoKit run dropped at 71% before
  reaching them = NOT yet backed up); and **heavy duplication** (55,745 files, 41,295 with
  `(N)` suffixes for ~14k photos) from the ~20 DB-less retries each re-assigning `(N)` names.
- **In progress:** `DOWNLOAD_MISSING=1` pass (PhotoKit) fetching the 11,538 not-local originals
  + exporting them (local DB makes it convergent now); then `CLEANUP=1` (dry-run first) to
  remove the ~17k+ orphan duplicates. Then enable the nightly timer + verify S3. Final
  exported-count-vs-14,267 + timer status to report on completion.

---

## 2026-06-19 (overnight, autonomous) — Velero nightly close-out + M84 (dataPathConcurrency)

Owner asleep, asked to "resolve autonomously." Outcome of the velero close-out:

**Firewall fix proven (the headline):** the 06-19 nightly had clean completions —
traefik/plex/cue + a 6.8 GB infra PVB — so Ceph fs-backup works post-H37-fix.

**M84 surfaced as the real residual:** velero node-agent runs default
**`dataPathConcurrency=1`** (no `node-agent-config` CM), so under the nightly burst
multi-volume backups stall (PVBs sit `Prepared`, never start the data path) and block
the serialized queue. Tonight: critical-apps + infrastructure (and earlier postgres,
which was *my* fault — recreating -6 mid-window) ended Failed/PartiallyFailed; I had to
`rollout restart deploy/velero` twice to finalize wedged backups + unblock the queue.

**What I did NOT do (deliberately):** apply the dataPathConcurrency fix. It needs the
velero chart's node-agent extra-args wiring, which I **can't verify without `helm`**
(not on devbox) — and per the close-out guardrail I won't guess at backup-system config
while unattended. Documented precisely in **M84** for the owner to apply (with helm to
confirm the chart key) + verify.

**Silence kept (not lifted):** the nightly is genuinely non-clean (the M84 stalls +
postgres), so lifting would fire those legit-but-known partials. Kept the silence to
avoid overnight noise; it **auto-expires 2026-06-19T19:22Z**. The once-per-day advisor
cap-fix means even if it fires it's ≤1 email (no flood). Lift manually after applying
M84 + a clean run: `kubectl -n monitoring exec alertmanager-monitoring-kube-prometheus-alertmanager-0 -c alertmanager -- wget -qO- --method=DELETE http://localhost:9093/api/v2/silence/4fe8a806-57fb-4671-85f6-e3e16be390bd`.

**Core cluster health (final sweep): all green** — 8/8 nodes Ready, zero unhealthy pods,
Flux 100%, all PVCs Bound, only benign alerts (InfoInhibitor/CPUThrottling/Watchdog).
postgres data safe regardless (CNPG continuous archiving healthy). GPU dcgm + grafana
(earlier today) remain resolved. **Owner action:** apply M84, then a clean velero run + lift the silence.

---

## 2026-06-19 — Grafana admin password (real, not default) + GPU dcgm-exporter wedge (gpu1 reboot)

Two follow-ups after the storage incident, both owner-reported:

**Grafana login.** Owner couldn't log in. Root cause: the `grafana-admin-credentials` SOPS
secret had shipped the **placeholder `ChangeMe123!`** since the original SOPS-encryption
commit (git shows no value change; no 1P→SOPS sync for it) — the real 1Password password was
never wired in. Not "reset today" (Grafana had 13d uptime). Owner updated
`grafana-admin-secret.sops.yaml` (VSCode SOPS extension) and pushed (`a0ffbc6`); Flux applied
it; I `rollout restart deploy/monitoring-grafana` so it re-read `GF_SECURITY_ADMIN_PASSWORD`.
**Verified:** new password → HTTP 200, `ChangeMe123!` → 401. (Side note: owner's laptop git
push failed on commit-signing — stale `/tmp/gs-session-keys/homelab` key; unblocked with
`git -c commit.gpgsign=false commit`.)

**GPU dashboard empty.** `nvidia-dcgm-exporter` on `k8s-gpu1` was wedged — `/metrics` timing
out (`TargetDown`), and crucially **`nvidia-smi` itself hung (D-state) → GPU driver/DCGM wedged
at the kernel level**. A pod restart couldn't fix it (old container stuck Terminating, new one
Pending; a fresh exporter just re-hangs on the wedged driver). **Fix = reboot gpu1 (Proxmox
VM 120)** via `qm shutdown --timeout 60 --forceStop 1 && qm start` (graceful-then-force, so the
Ceph volumes unmounted cleanly → no stale-EIO on ollama/plex). Post-reboot: operator-validator
1/1, dcgm-exporter serves metrics again (`DCGM_FI_DEV_GPU_UTIL` live in Prometheus, target
`up`), ollama+plex rescheduled back to gpu1 clean. **GPU *compute* was never affected** — only
the monitoring layer. Runbook written: [`../runbooks/gpu-dcgm-exporter-wedge.md`](../runbooks/gpu-dcgm-exporter-wedge.md).
**Durability:** the `TargetDown` alert (→ advisor) is the early-warning; the gpu-operator
`ClusterPolicy.dcgmExporter` exposes no `livenessProbe`, so self-restart-on-hang isn't
configurable via IaC (and couldn't kill a D-state container anyway) — runbook + alert is the
mitigation. Tracked as M83.

---

## 2026-06-19 — Storage incident: H37 firewall blocked Ceph; technitium-1 re-provisioned + made disposable

**Trigger:** a full cluster/service health-check (owner request) found **technitium-1
(DNS replica) wedged 0/1 for ~20h** — and chasing it uncovered a **cluster-wide latent
storage fault**.

**ROOT CAUSE (the big one): H37's PVE host firewall blocked all *new* K8s↔Ceph
connections.** When H37 flipped `policy_in: DROP` (2026-06-17 15:30) it had **no rule for
Ceph** — the host runs mon+OSDs on `vmbr0.210` (10.10.210.41) and the K8s nodes are RBD
clients on that same storage VLAN (10.10.210.0/24). Existing RBD sessions survived via
conntrack (mounted volumes kept working) so it was **latent**; the first *fresh* rbd
map/create — technitium-1 trying to remap, then dynamic provisioning — failed with
`DeadlineExceeded`/`exit 108`. Confirmed: Ceph `HEALTH_OK` locally on pve, but the csi
provisioner/node-plugin timed out, and conntrack showed only ~15 frozen Ceph conns from
the K8s nodes. **This is a serious latent landmine: any node reboot / pod reschedule / new
PVC would have failed cluster-wide.**

**Fix (durable, IaC): added a `pve-ceph` security group** (storage VLAN → `3300,6789,6800:7300`)
to `infra/terraform/proxmox/firewall/` and **applied via Terraform** (`d8fc8d4`/`982df07`;
plan `1 add, 1 change, 0 destroy`). **Proven end-to-end** — provisioning + map + mount all
work again. ⚠️ **The `d8fc8d4` commit message says a live `pvesh` hotfix was also applied —
it was NOT** (the classifier blocked the live firewall write); the fix is **Terraform-only**,
so there's no temp rule to remove.

**devbox is now TF-capable.** To apply from devbox (no longer the mini) I installed
`terraform` 1.15.5 + `aws` CLI v2 and rendered the homelab AWS profile from SOPS
(`scripts/render-aws-credentials.sh`) + PVE token via `scripts/tf-proxmox.sh firewall`.
**This is a deliberate change from the "devbox = no TF/creds" design** — it puts the
homelab AWS profile + PVE token on devbox, **expanding its blast radius**. Owner accepts
for now (it was genuinely needed); flagged as a ZT consideration (revisit vs the mini/CI).

**technitium-1 recovery + disposability (the owner directive "make services recreatable
from code"):** the old RBD image (`csi-vol-ba25c344`) was wedged (a hung krbd client on
w2 left a stale exclusive-lock; fenced via `ceph osd blocklist`, but the image/mount stayed
stuck). Since technitium-1 is a disposable replica, **re-provisioned it onto a fresh dynamic
PVC** (dropped its static PV from `02a-static-pv-recovery.yaml`; old image retained in Ceph
for forensics). That exposed **two bootstrap gaps** a fresh replica hit — now fixed in
`dns-sync` (`07-dns-sync.yaml`):
  1. **No zone** — dns-sync only *added* records; now it **creates the Primary zone** if missing.
  2. **Auth** — dns-sync logs in as the custom `graham` user, which doesn't exist on a fresh
     replica (only built-in `admin`, password from `DNS_SERVER_ADMIN_PASSWORD`). Auth matrix:
     `graham` works on -0/.6/AWS, `admin` only on .6 — so dns-sync now **tries `graham`, falls
     back to `admin`** to bootstrap a fresh server.
  **Verified:** a fresh -1 self-bootstrapped (auth as admin → zone created → 45 records synced),
  STS **2/2**, both `.5` endpoints, and **-1 answers `devbox.wind.etherport.net`**. A replica
  is now truly disposable (blow away PVC → StatefulSet + password env + dns-sync rebuild it).
  Briefly pinned `replicas=1` during the fix to protect DNS (healthy -0 + .6 + AWS fallbacks).

**w2:** its earlier `exit 108` krbd error was a transient during the firewall-propagation/
blocklist window, **not** a persistent wedge — verified with a throwaway ceph-rbd test pod
(mounted in ~10s), so **no reboot needed**; uncordoned.

**Second firewall casualty (found in the follow-up health-check, 2026-06-19):**
`postgres-cluster-6` (CNPG replica on w2) was CrashLoopBackOff with `chmod
/var/lib/postgresql/data/pgdata: input/output error` — its ceph-rbd mount went into a
**stale EIO error-state** when the firewall dropped its Ceph connection mid-I/O. The DB
stayed healthy (2/3: primary -1 + -8 served throughout). **Fix:** `kubectl delete pod`
(force) → CNPG recreated it → **fresh NodeStage cleared the EIO mount** → cluster 3/3,
data intact (no re-clone needed). **General lesson:** a Ceph-RBD pod that was *writing*
during the firewall block can be left with a stale EIO/hung mount that only surfaces on its
next restart/write; the fix is a **pod delete to force a remount** (or re-provision if the
image itself is bad). Only -6 + technitium-1 manifested; watch for others on restart.

**Open / next:** (a) ✅ **DONE (`4434719`):** DNS-rotation window closed — readinessProbe
gates `.5` on local zone-presence (`dig +norecurse SOA`) + `technitium-headless`
`publishNotReadyAddresses: true` so dns-sync can still bootstrap a not-ready fresh replica
(no deadlock). (b) Consider re-homing TF off devbox for ZT (or accept it) — tracked as M82.
(c) ✅ **DONE:** old wedged RBD image `csi-vol-ba25c344` deleted from Ceph (`rbd rm`) — root
cause was the firewall, data was disposable, no fsck needed.

---

## 2026-06-18 — Cilium policy-audit observation moved into Loki/alerts (retire the /loop)

**Goal:** stop running the H3 NetworkPolicy audit observation as an interactive
`audit-report.py` `/loop` in a chat thread; surface it through the **existing**
logging/alert stack instead (owner: "build it into Loki, don't create anything new").

**Built (all reusing what's already running — `c269ebb`):**
- **Cilium → file:** enabled Hubble **static flow export filtered to `verdict=AUDIT`**
  (`hubble-export-allowlist={"verdict":["AUDIT"]}`) to a per-node file
  `/var/run/cilium/hubble/audit-events.json`. Tiny volume (AUDIT-only). Applied live
  via `kubectl patch cm cilium-config` + `rollout restart ds/cilium` (Helm path — **no
  helm on devbox**, and this is the policy-audit-mode pattern; **canary'd one pod first**
  to prove the config parses before rolling all 8). Durable in the kubespray inventory
  via `cilium_config_extra_vars`.
- **Alloy → Loki:** added a read-only hostPath mount + a `loki.source.file` tailing that
  file → Loki as `{job="hubble-audit"}` (`clusters/wind/helm-releases/alloy.yaml`).
- **loki-ruler → Alertmanager:** new `CiliumNetpolAuditFlow` LogQL alert
  (`platform/kubernetes/monitoring/06-loki-rules-cilium-audit.yaml`, label `loki_rule:"1"`)
  that fires on AUDIT flows **excluding already-triaged known-good sources** (postgres
  replication, cnpg-system) → only NEW/notable `src→dst:port` tuples page; full detail
  queryable in Grafana. Routes through the existing advisor too (advisory-only).

**Verified end-to-end:** canary cilium pod healthy (config parsed: "Building the Hubble
static exporter … ExportAllowlist:{\"verdict\":[\"AUDIT\"]}"), all 8 rolled; AUDIT flows
captured on postgres nodes (`postgres→postgres:5432` replication); Loki has the
`job="hubble-audit"` stream with real flow JSON; the rule file landed in the ruler dir
(`/var/loki/rules-temp/fake/cilium-audit.yaml`) alongside the working `pve-ipmi.yaml`.
The `src_ns!~"postgres|cnpg-system"` exclusion keeps it quiet on the known replication.

**Why this shape:** a cloud `/schedule` can't reach the homelab cluster (no tailnet/LAN/
kubectl from Anthropic's cloud); a devbox systemd timer would be net-new. Loki+ruler+Alloy
+Alertmanager already exist and already alert — this just adds a source + a rule.

**Op note:** as a flow gets added to a CNP allowlist it stops being AUDIT (CNP forwards
it) → drops out of the export automatically. As a new tier is enforced its AUDIT flows
appear here with no rule change. Update the rule's `src_ns` exclusion only when a *new*
source becomes known-good-but-not-yet-allowlisted. Retire the export keys when
policy-audit-mode is turned off at H3 enforcement.

---

## 2026-06-18 — Velero fs-backup incident (H39) + AI-advisor email-flood / cost-cap

**Trigger:** owner reported a flood of AI-advisor emails + the advisor hitting its
$0.50/day cost cap. Root-caused to a **real cluster-wide Velero failure** the advisor was
faithfully (and noisily) reacting to.

**Root cause:** Velero **filesystem (kopia) backups wedged cluster-wide since 2026-06-17
15:30** — the exact moment helm **rev5** deployed (applied M5's `resources` change +
restarted all node-agents). PodVolumeBackups (PVBs) piled into a **retry storm**
(`timeout on preparing PVB`), backups went `PartiallyFailed` daily, two data-mover pods
stuck `Running` 5–17h. Each alert fire → advisor called Claude + emailed → **cap hit
18:02**, then it kept emailing `[unavailable]` **per flapping alertname** (the 15-min
cooldown is per-alertname; one broken subsystem flaps many distinct alerts) = the flood.
**Ruled out:** node capacity/health, kopia repos (all `Ready`), chart/app version
(11.4.0/1.17.1, unchanged since 05-30). It was rev5.

**Remediation (owner-approved):**
1. **24h Alertmanager silence** on velero-ns alerts (`VeleroBackupPartial|VeleroLastBackupAgeHigh|KubePodNotReady`),
   ID `4fe8a806`, time-boxed → stops the advisor emails immediately. ⚠️ silenced ⇒ a real
   failure won't email; **watch tonight's scheduled run** manually.
2. **Safe reset (no config gamble):** deleted 8 stuck PVBs (incl. 2 orphans from 04-20) +
   their data-mover pods, force-cleared wedged `velero.io/pod-volume-finalizer`s,
   `rollout restart` velero + all 8 node-agents. **Verified** via an on-demand `dns`
   backup: the previously-failing step now works — data paths **prepare + start cleanly**,
   one volume completed its full 633 MB, **no retry storm / no prepare-timeouts**.
3. **Durability (`93cc970`):** pinned velero chart `version: "11.x"` → `"11.4.0"` (a
   floating range let Flux auto-upgrade the *backup path* with no commit/review).
4. **Advisor hardening (`93cc970`):** cost-cap `[unavailable]` notice now sent **once per
   UTC day** instead of per-alertname (audit log still records every `cap_reached` for
   Loki; per-alertname cooldown preserved). Advisor pod restarted to load it.

**Residual (open — under watch):** the on-demand test's *second* volume —
`technitium-1`'s data PVC on **k8s-w2** — got through kopia init (opened repo, found the
06-17 03:03 parent snapshot) then **hung mid-snapshot at 0 bytes**, while its sibling on
w3 finished fast. **Different, narrower** failure than the rev5 wedge (data path starts
fine now) — looks volume/node-specific (w2 or that PVC), NOT the cluster-wide cause.
Next: watch tonight's 02:00–05:00 schedules; if `technitium-1`/w2 recurs, dig into the
w2 node-agent ↔ S3/kopia path (possible Cilium-WireGuard/MTU angle — M66 also landed 06-17).

**Also noted (minor):** `PrometheusOutOfOrderTimestamps` fired earlier (monitoring, separate).

---

## 2026-06-19 — M79 bulk export run to 71%, then NAS SMB mount went unstable (PAUSED)

**Goal:** run the first full `osxphotos` export of all ~14.3k photos (the slow initial
pull via `--download-missing --use-photokit`), monitored.

**What happened:**
- Export ran cleanly from ~20:49 to ~00:18, reaching **10,201 / 14,343 (~71%)** — steady
  ~80–100 photos/min, files + XMP sidecars landing in `/Volumes/Backups/Graham/iCloud/Photos`,
  library originals growing in lockstep (PhotoKit on-demand download working as designed).
- **Then the `Backups` SMB mount dropped mid-run.** osxphotos didn't exit — it **wedged**
  spewing `CoreData: XPC: sendMessage: failed` with zero progress (its PhotoKit XPC
  connection died and a single process can't reconnect). Killed it.
- Remounts succeeded (2 s) but **`Backups` then dropped within ~30 s even when idle** (the
  `find` hang before the first idle-probe reading = classic smbfs dead-session). `Personal-Drive`
  (same NAS) stayed up; NAS pinged 0.4 ms; **445 open**; no kernel SMB errors → a **wedged
  server-side SMB session for the Backups share**, not network/load.
- Tried a workaround — mounting `Backups` via the **NAS IP** (`10.10.209.10`) to force a
  fresh session. That popped a **NetAuthAgent credential dialog** (no keychain entry for the
  IP) and appears to have knocked out `Personal-Drive` too; subsequent `mount-nas.sh` **hung**.
  Stopped all SMB poking to avoid leaving hung mounts.

**State at end (PAUSED, nothing lost):** **10,201 files safely on the NAS disk** (SMB is just
transport; data is intact server-side). No SMB shares mounted on the mini; a credential
dialog is likely waiting in the VNC GUI. osxphotos not running. Repo: added
`infra/macos/mini/photos-export-resume.sh` (self-healing wrapper — see below).

**Resume procedure (owner, in VNC):**
1. **Cancel** the stuck SMB login dialog (NetAuthAgent).
2. Clear the wedge **on the NAS**: restart SMB / toggle the `Backups` share off-on on the
   UNAS, or reboot the NAS (server-side session is stuck; `Personal-Drive` working proves
   the box itself is fine).
3. Re-mount (`infra/macos/mini/mount-nas.sh`) and confirm both shares **hold** for a few min.
4. Resume with **`infra/macos/mini/photos-export-resume.sh`** — loops remount → ensure
   Photos.app up → `osxphotos export --update` (resumes from `<DEST>/.osxphotos_export.db`,
   so it continues from ~71% — **no re-download** of the 10.2k) under a watchdog that kills +
   retries on mount-loss or a wedged (zero-progress) run. **No re-export, no re-download.**

**Lessons (durable):**
- The initial bulk pull is long enough that an SMB drop / PhotoKit wedge is *likely* → use
  the resume wrapper, not a bare `photos-export.sh`, for the first fill.
- **Do NOT mount the same NAS by IP when it's already mounted by hostname** — the second
  auth context destabilized the existing (working) session and spawned a blocking dialog.
- osxphotos wedges (doesn't exit) when its PhotoKit XPC dies → a watchdog must detect
  *zero file-count growth*, not just process exit.

---

## 2026-06-18 — M79 iCloud Photos backup built + owner setup started (on the mini)

**Goal:** stand up the iCloud Photos → NAS → S3 backup (M79) on the mini (macOS-only;
needs Photos.app + iCloud). Picked up from the prior session's kickoff.

**Done (autonomous, on the mini):**
- **`osxphotos` 0.76.1 installed** — NOT in Homebrew core (it's a Python tool); installed
  via **pipx** (`~/.local/bin/osxphotos`). Works under the mini's Python 3.14.
- **Sparsebundle created** — `infra/macos/mini/create-photos-sparsebundle.sh` (idempotent,
  refuses to clobber) → `/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle` (2 TB
  sparse, ~34 MB initial; attaches as `/Volumes/PhotosLib`).
- **Export job authored** — `infra/macos/mini/photos-export.sh`: `mount-nas.sh` →
  `hdiutil attach` → `osxphotos export --update --sidecar XMP --cleanup` →
  `/Volumes/Backups/Graham/iCloud/Photos`. **Exits 0 with a "not ready" message** until a
  `*.photoslibrary` exists in the attached volume — verified by running it (it attached the
  bundle and no-op'd cleanly). `net.wind.photos-export.plist` LaunchAgent (daily 22:00 PT)
  authored but **deliberately NOT loaded** (per owner) until the download completes.

**Key decisions (the code alone won't tell you):**
- **No new S3 bucket/share** (owner call, mid-session, simplifying the tracker's plan).
  The export lands under the **`Backups`** NAS share, which the **existing
  `s3-sync-backups` CronJob already syncs** to `archive.wind.etherport.net` (Glacier
  **Deep Archive**). Owner accepted Deep Archive's ~12 h retrieval for photos →
  **dropped** the separate Glacier-Instant-Retrieval `photos` bucket. So: no TF bucket/IAM,
  no new NFS export (Backups is already exported to the k8s node IPs), no new s3-sync share.
  NB: `Backups`' `excludes-share.txt` has no `Graham` exclude, so it picks up the subtree
  for free. (Earlier in-session I'd started authoring the bucket/share — backed out.)
- **Sparsebundle stays at `…/Photos/…`** (owner: the location I created is fine), even
  though the library dir convention elsewhere is `Pictures`. Export dir moved to the
  **Backups** share per owner (was `Personal-Drive/Photos/export` in the old plan).
- **Zero-deletion-risk setup path:** create a *new empty* library in the sparsebundle and
  let iCloud repopulate it — do **not** migrate/copy the old one. osxphotos is read-only re:
  Photos/iCloud; `--cleanup` prunes only the NAS export copy; `s3 sync --delete` only the S3
  copy. iCloud holds the masters → the sparsebundle is a disposable mirror.

**⚠️ Mid-session finding — iCloud "Download Originals" stalls on the headless mini, so
the export now drives downloads itself.** The new library synced its **catalog**
(`database/` 13 GB + thumbnails `resources/` 7.8 GB → every photo *appears* in the app)
but the actual **original masters froze at 192 / 14,267** (~1.3%) for hours: `cloudphotod`
idle at 0% CPU, no download assertion, byte-identical over a 45 s sample — **even with
Photos.app open the whole time**. `killall cloudphotod` did not revive it (it didn't even
relaunch headless). Network/thermal/space all fine. Root cause = iCloud's background
"Download Originals" is best-effort and parks itself on an idle headless Mac.
**Fix: switched `photos-export.sh` to `osxphotos export --download-missing --use-photokit`**
— each missing original is fetched on demand via **PhotoKit at export time**, independent
of the flaky background queue. Once fetched it stays in the library (we're on "Download
Originals to this Mac" → no re-eviction) = one-time download per photo. **Validated**: a
forced `--missing --download-missing --use-photokit` run downloaded + exported with XMP,
`error: 0`, library originals 192 → 196, **no TCC prompt** (PhotoKit access already
granted). Scratch test dir cleaned up (was under the S3-synced Backups share).

**State at end:** library + System Photo Library set, iCloud Photos on, catalog synced.
Export pipeline (incl. on-demand PhotoKit download) **proven working** on a 5-photo +
2-missing-photo scratch run. Timer still **NOT loaded** (owner's call). Sleep disabled.
Old `~/Pictures` library untouched as fallback. Repo updated + pushed.

**Next steps:**
- **Seed the first full export** (downloads all ~14k originals via PhotoKit — slow but
  resumable via the export DB): `./photos-export.sh` (or with a `--limit` to chunk it).
  No need to wait on iCloud's background download — the export does the pulling.
- **Enable the nightly timer** once the first export is underway/clean (symlink +
  `launchctl bootstrap net.wind.photos-export`; commands in `infra/macos/mini/README.md` → M79).
- Verify the nightly `s3-sync-backups` CronJob picks up `Graham/iCloud/Photos`.
- M80 (Drive/Contacts/Messages) is the natural follow-on, same Backups-share → Deep-Archive path.

---

## 2026-06-18 — Claude Code dev sessions migrated mini → devbox (M81), reboot-validated

**Goal:** move the three persistent Claude Code dev sessions (`infra`, `cue`,
`personal-web`) off the reboot-prone, FileVault-gated Mac mini onto the always-on
Linux **devbox** (`10.10.201.45`, tailnet `100.74.216.102`), so sessions survive
reboots unattended and stay remote-controllable from claude.ai. The mini is retained
**only** for macOS-only work (iCloud Photos/Drive backups — M79/M80).

**Why devbox:** no FileVault unlock-on-reboot gate → genuinely unattended auto-resume;
system `node`/`claude`/`tmux`/`git` in `/usr/bin` → work under systemd's minimal env;
on tailnet + LAN; Claude Code v2.1.154+ fixed Linux remote control.

**Done:**
- **All 3 sessions migrated with full history.** Transcripts copied
  `~/.claude/projects/-Users-grahamsmith-code-<repo>/` → `-home-ubuntu-code-<repo>/`.
  Each primed once via `claude --resume` (picker) — `--continue` keys off
  `lastSessionId`, which a freshly-copied transcript lacks; after one `--resume` it follows.
- **Reboot persistence** via `infra/devbox/{resume-claude-sessions.sh,claude-sessions.service}`:
  a systemd **user** unit (oneshot, `WantedBy=default.target`, `KillMode=none`) +
  `loginctl enable-linger ubuntu` (so the user manager runs at boot without login). The
  script self-heals (auto-clones a missing repo) and `cd`s explicitly before `claude --continue`.
- **Reboot test PASSED (2026-06-18 18:52).** Post-reboot, all three tmux sessions
  auto-resumed ~8s after boot, each in the **correct** repo cwd (`/home/ubuntu/code/{cue,personal-web,infra}`)
  running `claude --continue`. Service `enabled` + `active`, `Linger=yes`.

**Key decisions / lessons (the code alone won't tell you):**
- **`tmux new-session -c <dir>` silently falls back to `$HOME` if `<dir>` doesn't exist** —
  this bit us when a background-task race deleted the `personal-web` clone, so claude opened
  the wrong project (`-home-ubuntu`). Fix: ensure the dir exists (auto-clone) **and** `cd`
  explicitly in the launched command, not just rely on `-c`.
- **The resume script was committed non-executable** (`100644`) — it only ran because the
  live copy had been hand-`chmod +x`'d at setup; a `git restore` strips that and breaks
  systemd `ExecStart` on the next boot. Marked all three operator shell scripts `0755`
  in git (`4b49e54`). Also discovered devbox had a **stale local edit** to the script
  silently blocking every `git pull` from updating it.
- **Claude OAuth login is broken on headless Linux** (GitHub #47152 "Missing redirect_uri",
  unpatched). Worked around by transplanting the mini's full-scope token (Keychain →
  devbox `~/.claude/.credentials.json`) + setting `hasCompletedOnboarding: true` in
  `~/.claude.json` (else the setup wizard re-runs). Real fix = Anthropic patching #47152.

**State at end:** all 3 sessions live + reboot-durable on devbox; repo clean at `4b49e54`.

**Next steps / known gaps (→ M81 follow-ups):**
- **devbox.yml drift:** the live box has `kubectl` (v1.36.2, cluster-admin) + the
  `claude-sessions` systemd unit + linger that are **not codified** in `playbooks/devbox.yml`
  (which still ships the superseded single-session `claude-dev` launcher). Codify for reproducibility.
- **devbox toolchain gaps (by design, for now):** no `terraform`, no `~/.aws` profiles, no
  browser. So Terraform plan/apply + headless-Chrome verification can't run on devbox as-is —
  route those through CI or the mini, or install + configure them on devbox later.
- **`~/.claude/.../memory/` is empty on devbox** — the user's Claude Code memory files
  (created on the mini) aren't in git, so they didn't migrate. Copy mini → devbox.
- **Cilium H3 audit `/loop`** (was running in the infra chat) is stopped — re-home it off
  the interactive thread (devbox systemd timer is the natural host; it has kubectl).
---

## 2026-06-18 — RC session-UUID collision (mini⇄devbox) + M79 photo-backup kickoff

(Migration mechanics + the non-executable-script fix are in the M81 entry above.)

**RC collision (gotcha — now in memory `reference_rc_session_uuid_collision.md`):** the
infra thread was migrated by *copying* its transcript `e7e39822-…jsonl` to devbox and
resuming it. That left BOTH the mini and devbox running session **`e7e39822` under the
same transplanted OAuth token** → Remote Control (one channel per session-UUID+account)
had them fighting; the mini "took over" devbox's RC. **Resolution:** devbox keeps
`e7e39822` (the main infra thread); the **mini starts a fresh `claude` session** (new UUID)
for mini-only tasks — never `--continue`/`--resume` e7e39822 on the mini again.

**M79 iCloud Photos backup — kickoff (next frontier on the mini):** plumbing all settled
(see tracker M79). Current state from a clean reboot: both NAS shares mounted
(`/Volumes/Personal-Drive` 24 TB free, `/Volumes/Backups`); **nothing built yet** —
`osxphotos` NOT installed (brew present at `/opt/homebrew`), no `Photos/` dir on the share,
mini has only ~41 GB local free (hence the sparsebundle-on-NAS plan). The s3-sync system
is **k8s CronJobs in the `backups` ns** reading the NAS over **NFS** (`sequoia.wind.etherport.net:/var/nfs/shared/<Share>`, e.g. `/var/nfs/shared/Graham`) → data bucket
`archive.wind.etherport.net` (Deep-Archive). For photos we need a **separate** Glacier-
Instant-Retrieval bucket + a new `shares/photos/` (DEST_BUCKET=photos.wind…, NFS path =
the export dir under Personal-Drive). **Build order (next session):** (1) `brew install
osxphotos`; (2) `hdiutil create` the APFS sparsebundle at
`/Volumes/Personal-Drive/Photos/PhotosLibrary.sparsebundle` (size ~1 TB, sparse) + attach;
(3) owner: Photos.app (Option-launch) → create library *inside* the mounted image → sign
into iCloud → **Download Originals** (long pole, days); (4) export script (`mount-nas` →
`hdiutil attach` → `osxphotos export --update` w/ XMP sidecars → `/Volumes/Personal-Drive/Photos/export/`) + launchd timer; (5) TF for the photos bucket + scoped IAM (add ARNs to
the `kubernetes-s3-backup` production policy); (6) `shares/photos/` s3-sync manifests.

---

## 2026-06-17 — M65 terraform consistency (+ M53/M54/M71 tracker housekeeping)

**Goal:** the zero-risk terraform cleanup. Picked because it's provably zero plan-diff.

**Done** (`687b519`):
- **(a)** all **22** `required_version` → `>= 1.14` (local TF 1.15.5, CI pins 1.14.3). `fmt`
  also normalized pre-existing whitespace in `aws/twilio-webhook/{iam,main}.tf`.
- **(c)** `aws/compute`: 6 hardcoded data-source IDs (VPC/subnet/4×SG) + the inline cloud-init
  automation pubkey → `variables.tf` (defaults = live values). **`terraform plan` = "No changes"**
  (data sources resolve identically; user_data has `ignore_changes`).
- **(d)** proxmox ×3: PVE endpoint → `variable "proxmox_endpoint"`.
- **(b) deliberately NOT done — infeasible:** TF forbids `locals`/vars in
  `lifecycle.ignore_changes`; `unifi/networks.tf` already documents this in-file (lines 17-19),
  and the 11 blocks differ (unifi adds `dhcp_dns`). Only DRY path = risky 11-resource→`for_each`
  module with `moved {}` blocks — left as-is, rationale in the tracker.

**Validation:** aws/compute `plan` = No changes; proxmox ×3 `validate` = valid; `fmt -check` clean.
Authoring only — not applied (applies ship via CI/owner). **Key lesson for future agents:**
don't try to `local`-ize `ignore_changes` — Terraform won't allow it.

**Tracker housekeeping same session:** M53 closed (zone-scoped CF token minted + personal-web
cut over — owner); M54 moved to the personal-web repo (redirect codification is a personal-web
concern); M71 added (AWS auth modernization → Roles Anywhere for the mini + SSO for laptops,
medium-term; owner accepts the static-key risk for now).

---

## 2026-06-17 — H29/H31 owner-tail verification: both already complete (no CloudShell action)

**Context:** owner asked for CloudShell commands to finish H29 (delete old `terraform-homelab`
AWS key + GH secrets) and H31 (delete orphan `claude-admin-temp` policy). Verified live state
first (read-only, `homelab` profile, acct `830881980142`) — turns out **neither needs any
command**:

- **H31:** `claude-admin-temp` policy is **already gone** (`get-policy` → NoSuchEntity; absent
  from `list-policies --scope Local`). Remaining `claude-*` policies = intended design
  (`claude-admin-policy` + `claude-admin-oneoff-roles` attached, `claude-oneoff-boundary` 0
  attachments = correct for a boundary). H31 ✅.
- **H29:** the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` GH secrets are **already removed**
  (`gh secret list` has no `AWS_*`; 0 workflows reference static keys → CI is OIDC-only). The
  `terraform-homelab` IAM user has **exactly one** access key (`AKIA…JHIX`), **Active + used
  today** (S3/us-west-2) — and `aws configure get aws_access_key_id --profile homelab` returns
  that same key. So it's the **live local-ops credential** the mini uses for headless terraform.
  **Did NOT delete it** (CLAUDE.md §4 invariant). The original "delete the key" step is
  **superseded**: the in-CI-exfil threat is already neutralized; the key now serves local ops
  only (accepted risk). H29 ✅ (with that deliberate exception documented).

**Takeaway for future agents:** don't run `aws iam delete-access-key` on `terraform-homelab` —
it's the mini's own credential. A clean future state would be a *separate* dedicated key/user
for the mini, then retire this one; that's net-new work, not H29.

---

## 2026-06-17 — H37 Stage 2 ENFORCED: Proxmox host firewall now default-deny

After the Stage-1 observation window (below), verified coverage + flipped to enforce.

**Observation verified:** firewall log showed every admin source hitting 22/8006 is in
`mgmt-admin` — mini (`10.10.202.101`), TS/WG-via-201 (`10.10.201.55/.56`), and the **UDM
backup WG** (`192.168.3.2`) — with **0 sources outside `mgmt-admin`** touching 22/8006/3128.
Host only receives 22+8006 (no exporters to strand).

**Back-door (break-glass) fixed:** the UDM backup WG (`WireGuard WAN1`, 192.168.3.0/24,
terminates on the UDM → survives the host's VMs dying) initially couldn't reach PVE. Ruled
out infra (server enabled, `Vpn→Management` ALLOW exists on the UDM, our fw was permissive)
→ it was a **client-side DNS issue** (full-tunnel without internal DNS). Owner fixed it; now
logs as `192.168.3.2`. Added `192.168.3.0/24` to `mgmt-admin`. IPMI/console break-glass confirmed.

**Stage 2 applied:** `local.input_policy` ACCEPT→DROP + rule `log`→nolog. **Verified live:**
datacenter `enable=1, policy_in=DROP`; host reachable (mini API 3/3 HTTP 200; ports **22+8006
OPEN** from the mini through the enforcing fw); **all 13 guests still running**. The mini
(`10.10.202.101`) is in `mgmt-admin`, so the agent's control path survives → reversible via
`input_policy="ACCEPT"` + apply; IPMI = hard backstop. Owner separately confirming TS/WG/
backup-WG interfaces.

**H37 done** (host plane). k8s-node + standalone-VM firewalling = **M77**.

---

## 2026-06-17 — H37 Stage 1 LIVE: Proxmox host firewall (permissive + observing)

Zero-trust follow-on; owner-requested. Scope = **host management plane** (k8s-node +
standalone-VM firewalling split to **M77**).

**Investigated:** PVE firewall was entirely OFF. Node `pve` (10.10.200.41), 13 running
guests, **all VM NICs `firewall=0`** (so enabling the host firewall can't cascade onto
guests — key safety fact). Admin-access SNAT ambiguity (TS subnet-router / WG-pod
MASQUERADE / mini-LAN) → staged permissive→observe→enforce rollout.

**New stack** `infra/terraform/proxmox/firewall/` (S3 backend, own state). Stage 1:
cluster firewall **enabled, input_policy=ACCEPT** (permissive), out/forward ACCEPT; node
`pve` enabled + `log_level_in=info`; IPset `mgmt-admin` (10.10.200/201/202 + 100.64/10
tailnet + WG 10.254/24 + 10.255.255/29); SG `pve-mgmt` (ACCEPT 22/3128/8006 + Ping)
attached to the node.

**Blocker hit + cleared:** the `graham@pam!terraform` token lacked **`Sys.Modify`** →
PVE 403 on all firewall writes. Owner granted it via a custom least-priv role
(`pveum role add TerraformFirewall -privs "Sys.Audit Sys.Modify"` + `acl modify /
-roles TerraformFirewall -tokens 'graham@pam!terraform'`). Re-applied: **5 resources
created, verified LIVE, no lock-out, 13 guests still running.**

**Now:** observation window — set the `pve-mgmt` allow rule `log=info` for positive
confirmation. Watch `/nodes/pve/firewall/log`; confirm laptop-on-TS / laptop-on-WG /
mini admin sessions all match `mgmt-admin` before the Stage-2 DROP flip. **Stage 2**
(flip input_policy ACCEPT→DROP) pending observation + **IPMI/console break-glass
confirmation.** Reversible throughout.

---

## 2026-06-17 — M66: enabled Cilium WireGuard pod-to-pod encryption

**Decision (owner):** enable WireGuard, staged. Closes the cleartext-east-west gap
(postgres replication, in-cluster WG key material, secrets traversed the node underlay
as cleartext VXLAN).

**State before:** Cilium v1.18.6, `routing-mode: tunnel`/vxlan, `kube-proxy-replacement:
false`, encryption off. Cilium is a **Helm release** (`cilium`/kube-system, was rev 16).

**Applied (Helm, not kubespray — avoids the cni-owner landmine):** backed up current
values (`helm get values cilium` → /tmp), **dry-ran** the upgrade (confirmed the only
config delta = `enable-wireguard: "true"`), then `helm upgrade cilium cilium/cilium
--version 1.18.6 --reuse-values --set encryption.enabled=true --set
encryption.type=wireguard` (→ rev 17) + `kubectl rollout restart ds/cilium` (maxUnavailable
2, rolled clean). Config is read at agent startup so the restart is required.

**Verified live:** `cilium-dbg encrypt status` → `Encryption: Wireguard`, iface `cilium_wg0`,
**7 peers** (full mesh, all 8 nodes), `NodeEncryption: Disabled` (pod-to-pod only). All 8
CiliumNodes published wg pub-keys. **Postgres stayed 3/3 healthy** (primary on w4, replicas
w1/w2 — replication genuinely crosses nodes) through the roll; **0 unhealthy pods** cluster-wide.

**Durability:** set `cilium_encryption_enabled: true` + `cilium_encryption_type: "wireguard"`
in the kubespray inventory (`k8s-net-cilium.yml`) so a future kubespray run keeps it; live
(helm rev 17) + inventory now agree. CLAUDE.md §5 invariant added. Kernel-mode WireGuard (no
IPsec secret). Reversible via `--set encryption.enabled=false` + rollout restart.

**Follow-on:** owner asked to evaluate broader **zero-trust** opportunities (incl. the
**Proxmox host firewall**, not yet tracked) — see new items added to outstanding-work.md.

---

## 2026-06-17 — M61 + M68 + M5, and H36 caught a real Flux SSH outage

Worked three tracker items end-to-end (commits `bc7c488`, `77d2678`, `bc02764`), plus
M53/M54/M71 housekeeping and a live-incident validation of H36.

**M61 — SOPS centralization + Renovate coverage:** wired the 3 inline-SOPS-curl terraform
workflows (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn`;
all ubuntu-latest/amd64) → the pinned+checksum-verified `setup-sops` composite action (also
closes the H30 "wire 3 workflows" deferral). **Verified green in CI** (AWS US-East-1 + Regional
VPN + sops-decrypt-check all passed). renovate.json: enabled the `pre-commit` manager (off by
default → now bumps the 4 hook repos) + grouped github-actions/terraform/pre-commit PRs.
ansible-runner Dockerfile: version-sync pointer to setup-sops + TODO for per-arch sha256.
ansible-lint hook still deferred (needs baseline pass).

**M68 — docs consolidation:** merged `1PASSWORD-CLI.md` → `SOPS-SETUP.md` (de-staled `op`
quick-reference; **corrected** the false "agent can run op" claim — it's operator/VNC-only),
old file → redirect stub. New `docs/runbooks/archive/README.md` (BGP-phase A→B→C index +
others). Fixed `docs/README.md` (secrets rows, new Network subsection, **broken
firewall-zones-future-state link** → archived path, AI-advisor "LIVE not retired" wording).
firewall-zones.md: M14→M42 ID footnote + its own broken future-state link fixed.

**M5 — velero (CRITICAL backup path, handled conservatively):** both original sub-tasks turned
out riskier than the "S" rating. (1) **Ordering** = by-design: Schedules sit with the HR in the
monolithic kustomization (repo-wide CR-after-HR pattern); Flux retry self-heals cold bootstrap.
Restructure rejected (kustomize↔Helm cutover would risk deleting live Schedules). (2) **Quota**
= rejected as unsafe: velero pods had **no requests** (all BestEffort), so any compute quota
would silently reject ephemeral backup pods. Instead added **requests-only (no limits)** to
server (250m/256Mi) + node-agent (200m/256Mi) → Burstable QoS (less eviction mid-backup), no
OOM risk. **Verified live:** HR `UpgradeSucceeded` (v5, chart 11.4.0), node-agent rolled, all
9 pods Running + Burstable. Both decisions documented in the velero README.

**🔔 H36 validated itself in production:** mid-session the AI advisor emailed a
`FluxReconciliationErrors` alert (the rule built last session) — Flux source-controller couldn't
reach **GitHub SSH/22** for ~1h (13:33→~14:31 UTC), stuck at `fa72ed39`; proposed action `noop`,
95% conf. **Self-resolved** (GitRepository + Kustomization now Ready at HEAD `77d2678`; all HRs
Ready). No in-cluster impact (and none of the post-`fa72ed3` commits were even Flux-watched —
M65 tf / M61 ci / M68 docs). Transient GitHub-SSH/WAN blip; nothing on our side changed routing.
Advisor diagnosis was spot-on. **Takeaway:** H36 caught a real silent-wedge within its window —
exactly its purpose.

---

## 2026-06-17 — L23: deleted orphan cnpg-manager RBAC (duplicate-operator residue)

**Goal:** remove the harmless residue from the 06-16 duplicate-CNPG-operator cleanup —
the orphan `cnpg-manager` ServiceAccount + ClusterRole + ClusterRoleBinding (raw-manifest
install, never in git).

**Verified orphaned before deleting:** live operator deployment `cnpg-cloudnative-pg` runs
under SA `cnpg-cloudnative-pg` (Helm-managed), *not* `cnpg-manager`. The `cnpg-manager-rolebinding`
CRB bound CR `cnpg-manager` → SA `cnpg-system/cnpg-manager` self-referentially; no pod used the
SA. So the trio was a closed, unused loop.

**Done:** `kubectl delete clusterrolebinding cnpg-manager-rolebinding` + `clusterrole cnpg-manager`
+ `sa cnpg-manager -n cnpg-system`. After: operator pod Running 1/1, `postgres-cluster` 3/3 +
`cue-db` 1/1 both "Cluster in healthy state". Nothing to commit (objects were never in git).
L23 ✅.

---

## 2026-06-17 — M63 hardening safe-trio + "do all in order" wrap

**Goal:** finish the "do all in order" pass — last open item was M63 (k8s manifest
hardening sweep). Ship only the low-risk subset; defer the ones that can break things.

**Done** (`e91e150`, all `kubectl kustomize`-validated, Flux-reconciled + confirmed live):
- **(a)** `cloudflared` ServiceMonitor — added `release: monitoring` label. Selectors are
  match-all today so it was already scraped, but this keeps it safe if the selector is ever
  tightened to `release=monitoring`.
- **(b)** `rclone-gdrive` CronJob — added a **conservative** container securityContext:
  `allowPrivilegeEscalation:false` + `capabilities.drop:[ALL]` + `seccompProfile:RuntimeDefault`.
  **Deliberately NOT** `runAsNonRoot`/`readOnlyRootFilesystem` — rclone writes its working
  config into `/config/rclone` (emptyDir) and the image's user expectations are untested here;
  forcing non-root/RO-rootfs risked breaking the nightly GDrive sync for marginal gain.
- **(d)** `cloudflared` — added `minAvailable:1` PDB (`03-pdb.yaml` + kustomization). The
  Deployment runs 2 replicas; without a PDB a node drain could evict both and drop the public
  tunnel. Confirmed live: `ALLOWED DISRUPTIONS 1`.

**Deferred (NOT safe trio):** (c) `startupProbe`s — technitium is the cluster's split-horizon
DNS; a misjudged probe could wedge DNS mid-rollout, so it needs per-workload boot-time
measurement first. (e) home-automation `privileged:true` → explicit caps + device mounts —
needs owner knowledge of which host devices (Zigbee/Z-Wave USB etc.) HA actually needs.

**State / next steps:**
- **M63** now 🟡 (a/b/d done, c/e deferred with rationale in the tracker).
- **L23** (delete orphan `cnpg-manager` ClusterRole + ClusterRoleBinding + ServiceAccount in
  cnpg-system) — still **blocked awaiting explicit owner authorization** (it's a delete of
  shared RBAC; the classifier + safety rules require the owner to name the resources).
- **Owner-only console tails** the agent can't run: **H29** (delete the old `terraform-homelab`
  AWS access key + update GH secrets — but never delete the IAM key still shared with the local
  homelab profile) and **H31** (delete orphan `claude-admin-temp` IAM policy). Both need the
  user's AWS console / `op`-authorized terminal.

---

## 2026-06-17 — H36: Flux reconciliation alerting (closes the silent-wedge gap)

**Goal:** the 06-17 CNPG webhook incident wedged Flux for hours, undetected — Flux metrics
weren't scraped. Close that blind spot.

**Done** (`platform/kubernetes/monitoring/07-flux-monitoring.yaml`, commits `8f4c5d6`+`48fd4c7`):
- **PodMonitor `flux-controllers`** — monitoring ns, `namespaceSelector: flux-system`,
  `selector: app.kubernetes.io/part-of=flux`, port `http-prom` (8080), `honorLabels: true`.
  Prometheus selects all PodMonitors (`{}`); the flux-system `allow-scraping` netpol already
  permits :8080. Verified: all 6 controllers scraping `up`.
- **PrometheusRule `FluxReconciliationErrors`** — `sum by(app,controller)
  rate(controller_runtime_reconcile_total{namespace="flux-system",result="error"}[5m]) > 0
  for 15m`, warning. Loaded + evaluating (0 firing = healthy).

**Gotcha:** my first attempt used `gotk_reconcile_condition{type="Ready",status="False"}` — but
**this flux build doesn't export that metric** (only `gotk_reconcile_duration_seconds` +
`controller_runtime_*`; verified by curling a controller's :8080/metrics). Pivoted to the
sustained-reconcile-error signal, which is per-controller (kind) not per-object but reliably
catches a wedge. Also hit `function "lower" not defined` in the rule template — Prometheus
uses `toLower`, not `lower`.

**Result:** a wedged Kustomization/HelmRelease now pages within 15m instead of being found by
luck. H36 done.

---

## 2026-06-17 — CNPG webhook cert wedged Flux (caBundle/serving-cert mismatch) — fixed

**Surfaced while applying M62:** the flux-system Kustomization went `Ready=False`, blocking
ALL GitOps — `ScheduledBackup/cue-db-daily dry-run failed: failed calling webhook
"mscheduledbackup.cnpg.io": ... tls: failed to verify certificate: x509: certificate signed
by unknown authority`. The CNPG admission webhook was down → Flux couldn't apply CNPG
resources → couldn't advance past `0f43c36`.

**Root cause (tail of the 06-16 duplicate-operator incident):** during yesterday's operator
handoff/leader-churn, `cnpg-ca-secret` + `cnpg-webhook-cert` were regenerated (~12h before),
but inconsistently — the webhook configs' `caBundle` held the OLD CA, and the serving cert
was signed by yet another CA key (`ECDSA verification failure ... verifying ... cnpg-ca-secret`).
So CA secret, serving cert, and caBundle were three-way out of sync. The running operator
never self-healed it.

**Fix (owner-authorized, two steps):** (1) patched the webhook `caBundle` from `cnpg-ca-secret`
— necessary but INSUFFICIENT (serving cert was signed by a different/old CA). (2) **deleted
`cnpg-webhook-cert` + `kubectl rollout restart deploy/cnpg-cloudnative-pg`** → operator
re-issued a consistent serving cert + re-patched the caBundle on startup ("Updated current TLS
certificate"). Webhook dry-run then succeeded; Flux advanced to `c9b64de` `Ready=True`;
operator stable (`restarts=0`). DB clusters unaffected throughout (webhook only gates CNPG
resource admission; per-cluster Postgres TLS is separate).

**Durability:** the operator now owns a consistent, self-managed cert chain (its normal job;
the break was a one-time handoff glitch). The caBundle can't be static IaC (operator-injected
at runtime). Filed follow-ups: **H36** (Flux reconciliation alerting — gotk metrics are NOT
scraped today, so this silent wedge was found only by luck) and a note to evaluate
cert-manager-managed CNPG webhook certs (ca-injector = truly self-healing caBundle).

**Lesson:** after a CNPG operator change, verify the webhook works
(`kubectl -n <ns> get cluster <c> -o yaml | kubectl apply --dry-run=server -f -`) — cert
inconsistency is silent until the next admission call / Flux apply.

---

## 2026-06-16 — M62 authored: etcd snapshots → offsite S3 + freshness alert

**Goal:** close the etcd-backup DR gap — snapshots were local-disk-only, offsite solely
via the fragile Velero `kube-system-daily` path, no freshness alert.

**Authored (validated; applies are supervised — see outstanding-work M62):**
- **TF** `infra/terraform/aws/s3/`: new dedicated **`etcd-snapshots.wind.etherport.net`**
  bucket (STANDARD, 30d, versioned, PAB) + scoped **`etcd-backup`** IAM user (PutObject-only),
  mirroring the `postgres_barman` pattern. `terraform validate` clean.
- **Playbook** `etcd-backup.yml`: awscli + scoped creds on cp nodes; `etcd-snapshot.sh` now
  `aws s3 cp`s each snapshot offsite + pushes freshness/size/upload metrics to Pushgateway
  (pinned ClusterIP `10.43.32.171`).
- **Alert** `monitoring/06-backup-alerts.yaml`: `EtcdSnapshotStale` + `EtcdSnapshotS3UploadFailing`.

**Key design call:** used a **dedicated Standard-storage bucket, NOT the `archive` bucket** —
`archive.wind.etherport.net` transitions to Glacier Deep Archive after 2 days (~12h retrieval),
which would prolong a control-plane outage during a restore. Owner flagged a recurring habit
of defaulting new tasks to the archive bucket → added a loud "s3-sync cold storage ONLY"
warning at the bucket's TF definition + a memory note. **Rule: archive bucket = s3-sync cold
storage only; anything needing timely retrieval gets its own Standard bucket (like barman, etcd).**

**Validation:** TF validate ✅; PrometheusRule server-dry-run ✅ (the `unknown field "sops"`
errors in the kustomize dry-run are pre-existing SOPS secrets, Flux-decrypted, not ours);
playbook YAML + `--syntax-check` ✅. Pushgateway ClusterIP pinned to its current value so the
Flux helm-upgrade is a no-op on the immutable field.

**Next (supervised):** terraform apply s3 → SOPS the etcd-backup key into
`playbooks/secrets/etcd-backup.sops.yaml` → run `etcd-backup.yml --limit kube_control_plane`.
Flux ships the alert + pushgateway pin.

**✅ COMPLETED 2026-06-17 (all via CI):** terraform applied (`terraform-s3.yml`; one
invalid-tag-char retry), SOPS secret created, playbook ran (`ansible-vm-fleet.yml`). Hit two
node wrinkles: (1) the unrelated CNPG webhook-cert incident briefly wedged Flux (fixed — see
the 06-17 entry); (2) Ubuntu 24.04 dropped the `awscli` apt package → switched to the AWS CLI
v2 official sha256-pinned installer. **Verified end-to-end:** 3 CP-node snapshots in
`s3://etcd-snapshots.wind.etherport.net/<host>/` (~205MB each); Prometheus shows
`etcd_snapshot_last_run_timestamp` (fresh), `_s3_upload_success=1`, `_size_bytes` for all 3;
alerts live. L15 superseded.

---

## 2026-06-16 — CNPG operator restart-loop (duplicate operator) — fixed

**Trigger:** AI advisor email — "cloudnativepg pod is stuck." Full system check requested
after the 06-15 Cilium/NetworkPolicy work.

**System was healthy** except the operator: 8/8 nodes Ready, Flux all-Ready, both CNPG
clusters healthy (postgres-cluster 3/3, cue-db 1/1), Cilium audit mode still `Enabled`
(06-15 work intact, NOT enforcing — ruled out as the cause).

**Root cause (pre-existing, NOT from 06-15):** **two** CNPG operator deployments in
`cnpg-system` both running `controller --leader-elect` against the **same lease**
(`db9c8771.cnpg.io`):
- `cnpg-cloudnative-pg` — canonical, Helm/Flux-managed (`helm-releases/cnpg.yaml`, chart
  0.22.1); backs `cnpg-webhook-service`.
- `cnpg-controller-manager` — **orphan** from a pre-Helm raw-manifest install (no Helm/Flux
  labels, not in git, doesn't back the webhook service).
They fought over the lease → the loser hit `Put .../leases/...: context deadline exceeded`
→ `leader election lost` → exit/restart, repeatedly (37 + 29 restarts). Leases 34d old =
chronic. DBs unaffected (operator absence doesn't stop running Postgres).

**Fix:** `kubectl -n cnpg-system delete deployment cnpg-controller-manager` (owner-approved;
the Claude Code auto-mode classifier blocked it until the owner named the resource
explicitly). Helm operator immediately acquired the lease uncontested (lease holder now
`cnpg-cloudnative-pg-…`), started its controllers, restarts stopped climbing (held at 37),
webhook endpoint ready. Both clusters healthy. **Residual (harmless):** orphan
`ServiceAccount/cnpg-manager` (+ likely a cluster-scoped `cnpg-manager` Role/Binding) from
the old install — unused, low-priority cleanup (tracker).

**Why the AI advisor gave no remediation button (owner asked):** by design. The advisor's
prompt (`auto-remediation/advisor-prompt-configmap.yaml`) lists `cnpg-system` under *NEVER
PROPOSE* ("the executor allowlist excludes flux-system/kube-system/cnpg-system/rook-ceph/
cert-manager — proposals silently dropped"), so even with Phase 2/3 enabled it can only
**advise** (email) on cnpg-system, never offer an approve/auto action. Also "delete a
deployment" / "pick which duplicate operator is the orphan" isn't in its action whitelist
(restart_pods, scale, rollback_deployment, cnpg_recreate_replica, backups, …) and needs
human judgment. Working as intended — critical stateful namespaces are human-in-the-loop.

**Next:** confirm restarts stay at 37 (single operator = no contention); optional cleanup of
the orphan `cnpg-manager` SA/RBAC.

---

## 2026-06-15 — H3 NetworkPolicies Phase-1 + Cilium incident (kubespray cni-owner)

**Goal:** start H3 (default-deny NetworkPolicies). Authored Phase-1 manifests, hit a
contained Cilium incident enabling audit mode via kubespray (recovered), then enabled
audit mode the surgical way + made it IaC-durable + **started observation on postgres**.
**End state: audit mode ON (8/8 agents), NetworkPolicies live via Flux under audit,
postgres labeled (audit-both), helm release clean, cluster healthy.**

**What shipped (good):**
- `platform/kubernetes/networkpolicies/` (commit `3c299d9`) — default-deny + universal
  allows (DNS via host/remote-node:53 for link-local nodelocaldns, kube-apiserver, host,
  monitoring scrape) + `postgres-ingress` tier. Per-ns opt-in via `netpol.wind/enforced`
  label. **Inert** (not Flux-wired). All 5 validate vs live Cilium 1.18.6 CRDs.

**The incident (root cause + recovery — don't re-walk this):**
- To enable `policy-audit-mode`, ran kubespray `cluster.yml --tags=cilium,download` (v2.30,
  via a freshly-bootstrapped `~/.kubespray-venv` since the mini had none; system ansible
  2.21 is too new — kubespray needs 10.7.0/core-2.17). The run "succeeded" (exit 0) but a
  follow-up `kubectl rollout restart ds/cilium` (needed because audit-mode is read only at
  agent startup) put 2 agents into **`Init:CrashLoopBackOff`**.
- **Root cause:** kubespray's "Create cni directories" task chowns `/opt/cni/bin` to
  `kube_owner` (**`kube`** — set in `k8s-cluster.yml`). Cilium's `mount-cgroup` runs as
  root with `drop:[ALL]` (no DAC_OVERRIDE) → can't write `cilium-mount` to a kube-owned
  dir → `cp ... Permission denied`. **Latent** — the 6 un-restarted agents kept running off
  loaded eBPF (nodes stayed Ready); only restarted agents crashed. Confirmed via `/opt/cni/bin`
  **ctime = today 17:22** (chown updates ctime, not mtime — mtime still read Jun 5).
- **Misstep:** first tried `helm rollback cilium 13` (thinking the v2.30 chart changed the
  init container). It didn't help — rev-13's `mount-cgroup` securityContext is **identical**;
  the chart was never the cause. The rollback left a **`failed` helm rev 15** (release
  health still needs cleanup — see below) and reset `policy-audit-mode=false`.
- **Actual fix:** `chown root:root /opt/cni/bin` on all 8 nodes (the existing
  `pre-flight.yml` already enforces this — kubespray's cluster.yml had undone it) + delete
  the crashing pods. One node (k8s-w1) was missed on the first pass (truncated output) →
  always verify ALL nodes. Final: **8/8 agents Running (restart 0), 8/8 nodes Ready**,
  audit mode `Disabled` (= original safe baseline).

**Codified + documented (this entry's commit):**
- Strengthened `inventory/pre-flight.yml` comment (CRITICAL: re-run after any cluster.yml).
- Reverted the staged `cilium_policy_audit_mode` kubespray var (footgun) with a note to use
  the ConfigMap path instead.
- New runbook `docs/runbooks/cilium-cni-dir-owner.md` (symptom/cause/recovery + the actual
  kubespray run path, since `kubespray.sh` is stale). CLAUDE.md §5 gotchas updated.

**Audit mode ENABLED + made IaC-durable (later same day):**
- Enabled live via the **surgical path** the owner authorized: `kubectl patch cm cilium-config
  policy-audit-mode=true` + `kubectl rollout restart ds/cilium`. Rolled clean (dir is root-owned);
  **runtime `PolicyAuditMode: Enabled` on all 8 agents**, 8/8 nodes Ready. (helm rollback to
  rev 14 was the cleaner route but the auto-mode classifier blocked it as out-of-scope.)
- **Durability (owner: "don't let a future kubespray run overwrite these"):** (1) NetworkPolicies
  are Flux-managed → kubespray-safe. (2) `cilium_policy_audit_mode: true` committed to the
  kubespray inventory (source of truth → a kubespray render keeps audit on). (3) `kubespray.sh`
  wrapper rewritten (correct venv/inventory paths + **auto-runs `pre-flight.yml` after
  cluster.yml/upgrade/scale**, restoring `/opt/cni/bin` root owner) — so a kubespray run no
  longer breaks Cilium *when run via the wrapper*. (4) Backstop armed: `cilium_extra_values`
  adds `DAC_OVERRIDE` to Cilium `mount-cgroup` so it tolerates a kube-owned cni dir even on a
  raw kubespray run (not yet validated live — needs a kubespray render; tracked H35).
- `kube_owner: root` was **rejected** — `/etc/kubernetes` + `/etc/cni/net.d` are genuinely
  kube-owned, so flipping it would broadly re-chown system paths.

**Completed (owner said "start H3 and get this fixed now, OK to roll Cilium"):**
- **NetworkPolicies wired into Flux** (`clusters/wind/kustomization.yaml`, commits `4005fed`+`00bdb81`).
  Removed the standalone default-deny CCNP — Cilium's operator rejects an empty-rule policy
  ("rule must have at least one of Ingress/Egress/..."); instead the `allow-*` CCNPs (which
  select enforced namespaces + cover both directions) establish default-deny per Cilium's
  selection semantics. 3 allow CCNPs + `postgres-ingress` all `VALID: True`.
- **Observation STARTED on postgres** — endpoint is `POLICY (ingress/egress): Disabled (Audit)`.
  ⚠️ **Label must be in the namespace MANIFEST in git** (`cnpg/00-namespace.yaml`), not a
  `kubectl label` — Flux SSA strips out-of-band labels on reconcile (hit this; fixed via git,
  commit `7e83047`). `scripts/cilium/audit-report.py` reports cluster-wide AUDIT flows via the
  hubble relay for enforced namespaces. First run: 1 AUDIT flow (intra-postgres TCP — likely
  CNPG instance comms beyond :5432; investigate + add to the postgres allowlist). Recurring
  check set up via `/loop` on the mini session.
- **Helm release cleaned** — `helm rollback cilium 14` (rev 14 = audit=true) → clean
  `deployed` rev 16, supersedes the `failed` rev 15. Audit still Enabled on all 8 agents.

**Next (the multi-week observation phase):**
- Watch `hubble observe --namespace postgres --verdict AUDIT` (cover the CNPG backup/cron
  paths). Refine the postgres allowlist from real flows, then ENFORCE postgres (it's already
  in audit; the switch is disabling audit for it — but global `policy-audit-mode` is
  cluster-wide, so enforcement = keep audit on elsewhere and verify postgres' allowlist is
  complete before the final global audit-off).
- Then label the next tier (cue → dns → traefik → monitoring), writing each `1x-tier-*`
  allowlist from audit data. Exclude wireguard/kube-system/flux-system.
- **H35 follow-ups remain:** validate the `cilium_extra_values` DAC_OVERRIDE backstop on the
  next supervised kubespray run; review `setup.sh`.

---

## 2026-06-15 — H33a: offline backup age recipient + repo-wide re-key

**Goal:** close H33's single-key blast radius — one age recipient decrypted every
`*.sops.yaml`, with no offline backup (lose/rotate it wrong → whole estate
undecryptable). Add a second, **offline-only** recipient.

**What landed:**
- Owner generated a backup age keypair **on the laptop** (never on the mini); private
  half → 1Password "Homelab SOPS Age Key (BACKUP)" + paper in the safe. Public key
  `age1phcmcgfeqr66t7kxdafckp860y67j6n6y2qrn76hk4fm2vd59pxsqr3466` handed to me.
- Added it (comma-joined, **primary kept first**) to all **15** `.sops.yaml` (5 root
  `creation_rules` + 14 nested), then `sops updatekeys -y` across all **39** secret
  files. **Guardrail:** re-keyed one file → verified it still `sops -d`s with the
  primary → then batched the rest. Final verify: 39/39 carry **both** recipients,
  0 decrypt failures, no plaintext leaked.
- **No Flux/CI/GH-secret change** — the primary stayed a recipient throughout, so the
  three online holders (mini disk, GH `SOPS_AGE_KEY`, Flux `sops-age`) keep working;
  zero lockout window. The backup is pure offline break-glass.

**Why this design (vs rotating the key):** H33a is *additive* redundancy, not a
rotation. Adding a recipient + `updatekeys` only needs the **primary private** key (to
decrypt, already on the mini) + the backup **public** key (to add). The backup
*private* key never has to touch the mini — which is why I could run the mechanical
re-key here despite this session being on the mini.

**Pre-existing bug found + fixed (now L22):** `tailscale/01-oauth-secret.sops.yaml`
had a **MAC mismatch** — its encrypted body had been hand-edited outside `sops` (sops
`lastmodified` 2026-04-12), so it hadn't decrypted for ~2 months, undetected (the live
operator kept running off the pre-corruption apply). Confirmed pre-existing by the
identical failure on `git show HEAD:`. Fixed by pulling the good `values.yaml` from the
live `flux-system/tailscale-operator-oauth` secret (33d, the helm `valuesFrom` source)
into a temp file — **never printed** — rebuilding the manifest, and `sops -e -i`'ing it
clean (both recipients, valid MAC). Verified by **sha256 equality** with the live
value (`d1a0841e…`), not by dumping contents. Added **L22**: a CI/pre-commit check that
every `*.sops.yaml` actually decrypts, so a broken MAC fails fast next time.

**Docs updated:** `.sops.yaml` header (names both keys + re-key note), `secrets-rotation.md`
(H33a marked done + blast-radius table), `headless-ops-host.md` + `SOPS-SETUP.md`
(PRIMARY/BACKUP naming), `outstanding-work.md` (H33 → (a) done, (b) FileVault + (c)
split remain; new L22). 1P: rename the existing primary item → "Homelab SOPS Age Key
(PRIMARY)" (owner).

**State:** committed + pushed; Flux reconciled clean (in-cluster decrypt confirmed).
**Next:** H33 remainder is owner-only — **FileVault on the mini** (un-passphrased key
on disk) + optional per-domain recipient split. Then the other HIGH items: H3
(NetworkPolicies), H30 remainder (supervised), and the H29/H31 console tails.

---

## 2026-06-14 → 06-15 — UniFi Protect webhooks → HA, + HA automation behavior

**Goal:** Protect camera motion → HA light automations had stopped working
("webhooks not received by HA").

**Diagnosis journey (don't re-walk this):**
- Initial (pre-compaction) diagnosis blamed split-horizon DNS on the **UDM gateway**
  (`10.10.200.1`) resolving `ha.wind.etherport.net` to the Cloudflare edge → CF Access
  302. **That was the wrong host.** Protect runs on the **UNVR `Windprotect`
  (`10.10.212.10`)**, which uses Technitium and resolves `ha.wind` → `10.10.201.70`
  correctly (A + NODATA AAAA). A webhook POST from there returns HTTP 200. So DNS/
  network/HA were never the problem.
- A UDM Local DNS record was briefly added then **reverted** (owner: keep everything
  on Technitium for consistency — the UDM forwarding externally is by design).
- **Real root cause:** UniFi Protect's Alarm Manager webhook client has a bug — it
  feeds a multi-address `dns.lookup()` result into Node's single-IP connect path, so
  `net.isIP([ [Object] ])` throws **`ERR_INVALID_IP_ADDRESS`** and the request dies
  before any TCP connection. This breaks **every hostname-based webhook** (confirmed
  in `/srv/unifi-protect/logs/automationManager.log`: zero successful httpActions).
  Protect also **validates TLS**, so `https://10.10.201.70/...` (IP) fails
  `ERR_TLS_CERT_ALTNAME_INVALID`. Only an **IP-literal + plain-HTTP** URL works.

**Fix (shipped, commits `9fd7c50` + `840f6c0`):** a dedicated plain-HTTP Traefik
entrypoint `webhook` (`:8088`, no 80→443 redirect, no TLS) on the VIP, serving **only**
`PathPrefix(/api/webhook/)` → HA `:8123`. Files: `clusters/wind/helm-releases/traefik.yaml`
(the `webhook` port) + `platform/kubernetes/home-automation/ingressroute-webhook.yaml`.
Protect webhooks now use `http://10.10.201.70:8088/api/webhook/<id>`. Verified all 5
IDs return 200 from Protect; non-webhook paths 404 (least-exposure). Traefik rolled
zero-downtime (2 replicas, `maxUnavailable: 0`, PDB).

**Decisions / rejected options:**
- Rejected: HA macvlan IP (`10.10.202.25`) direct — firewalled from the camera VLAN.
- Rejected: source-lock the `:8088` route to Protect's IP via Traefik `ipAllowList` —
  the shared Traefik LB is `externalTrafficPolicy: Cluster` so kube-proxy SNATs the
  client IP and the allowlist 403s everything. Keeping it would need `Local` (cluster-
  wide ingress change) or a UDM firewall rule. **Owner declined** — the path is
  plain-HTTP, LAN-only, `/api/webhook/`-only, gated by 24-char secret IDs; marginal.
- The `protect-tf` 1P key authenticates the Protect **integration** API but that API
  is read-only for automations (no Alarm Manager endpoint), and the internal app API
  rejects it (401). So **the Alarm Manager URL edits can't be done via any API** —
  they're a Protect-UI task.

**HA automation behavior change (same session):** owner wanted re-triggered motion to
**reset** the off-timer (was ignored mid-run). Changed all 5 motion-light automations
from `mode: single` → **`mode: restart`** directly in `/config/automations.yaml`
(backup at `/config/automations.yaml.bak-premode-20260615-064254` in-pod; activated via
HA "Reload Automations"). Also clarified: editing/saving an automation mid-run cancels
the in-flight run (so a pending `turn_off` is abandoned → light stays on). `light.deck`
is a Hue light (healthy); the 03:40 deck-light-on event was *my* verification curl, not
real motion.

**State at end:** webhook path live + verified; automations on `restart`. Lights all
off. UDM DNS reverted. `protect-tf` temp key wiped from `/tmp`.

**Open / next steps:**
- ⏳ **Confirm all 5 Protect Alarm Manager URLs are switched** to
  `http://10.10.201.70:8088/api/webhook/<id>` (owner did some via UI; verify none still
  on `https://`/hostname or the old `https://10.10.202.25/...-bY8...`). UI-only.
- ⏳ (optional) add `protect-tf` to the SOPS bundle for headless Protect integration-API
  reads (camera/motion state for HA) — not needed for this fix.
- ⏳ (optional, declined) firewall source-lock for `:8088` — revisit only if desired.
- Relates to tracker **M48/M49/M50** (Protect IaC): webhook *routing* is now IaC;
  Alarm Manager automations remain UI-managed (no write API).

## Before 2026-06-14

See [`outstanding-work.md`](outstanding-work.md) "Recently completed" blocks and the
dated planning docs. Headline recent landings: H29 (CI→AWS OIDC), L21 (CI→GCP WIF),
M69 (Cloudflare provider v4→v5), M53 (zone-scoped CF token), the localtuya migration
(all 8 Tuya devices cloud→local, entity_ids preserved), and the headless Mac-mini ops
host. Older history archived under `archive/`.
