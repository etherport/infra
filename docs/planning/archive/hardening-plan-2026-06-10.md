# Hardening Implementation Plan — 2026-06-10

> **Status: Archived 2026-06-24.** Work complete; kept as an ADR/historical record. Current state: `docs/planning/outstanding-work.md`.

Detailed, ready-to-execute plans for the HIGH items surfaced by the
[full-repo review](../outstanding-work.md#full-repo-review--2026-06-10)
(H3, H29–H34). Each section: **goal · verified facts · steps · verify · rollback ·
effort**. Designed so each item is independently executable and reversible.

> Produced by 5 architect passes that read the live repo. They corrected a few
> assumptions — flagged inline as **⚠ correction**.

## Recommended execution order (ROI × risk)

| # | Item | Why here | Effort | Risk |
|---|---|---|---|---|
| 1 | **H34** firewall narrow | mini self-applies, instantly reversible, removes the all-ports hole | S | low |
| 2 | **H31** kill `claude-admin-temp` + scope secrets | deletes a standing priv-esc primitive; read-only confirm first | S–M | low |
| 3 | **H29** CI → OIDC | retires 22 long-lived keys; free; mechanical; biggest credential win | M | med |
| 4 | **H30** SHA/digest pinning | mostly a Renovate preset + Flux one-liners | M | low |
| 5 | **H33** backup age recipient + rotation runbook | removes the single-key lockout risk | M | low |
| 6 | **H32** auto-remediation RBAC | hard-enforce the "never auto CNPG/Ceph" rule; stage carefully | M | med |
| 7 | **H3** NetworkPolicies | largest; phased over ~2 weeks of Hubble observation | L | high |

---

## H34 — Narrow + log the `trusted-admin-clients → Management` rule

**Goal:** the rule opens mini+laptop to the *entire* Management zone, `protocol: all`,
`logging: false`. Narrow to the admin ports actually used (22/443/8006), scope the
destination to named hosts, and turn logging on.

**Facts:** `infra/ansible/playbooks/udm-firewall.yml` already supports `udm_port_groups`,
dest `ip_group_name` + `port_group_name` (the `Management → Trusted (DNS)` policy is the
exact template). The mini self-applies (UDM creds from SOPS, Gateway reachable).

**Steps** — three edits in `udm-firewall.yml`:
1. Add port-group: `Mgmt-Admin-Ports` members `["22","443","8006"]`.
2. Add address-group: `mgmt-admin-hosts` members `["10.10.200.41"]` (PVE; add switch mgmt IPs as needed). The UDM/Gateway `10.10.200.1` is reached via the separate Clients→Gateway allow — don't add it.
3. Change the policy: `protocol: all → tcp`, `logging: false → true`, dest `zone_name: Management` + `ip_group_name: mgmt-admin-hosts` + `port_group_name: Mgmt-Admin-Ports`.

> **⚠ correction / gotcha:** the playbook reconciles policies **by name**, and (per the
> agent read) the `tasks` block only POSTs *creates* — there may be **no update/PUT task**.
> So either (a) keep the policy **name identical** and verify an update path exists, or
> (b) accept a rename and **manually delete the old `…→ Management (all)` policy in the
> UDM UI** after apply so the broad rule is provably gone. Verify before relying on
> in-place edits.

Apply from the mini:
```bash
cd ~/code/infra/infra/ansible
export UDM_USERNAME="$(sops -d playbooks/secrets/homelab-ops.sops.yaml | sed -n 's/^udm_tfadmin_user: *//p' | tr -d '"')"
export UDM_PASSWORD="$(sops -d playbooks/secrets/homelab-ops.sops.yaml | sed -n 's/^udm_tfadmin_password: *//p' | tr -d '"')"
ansible-playbook -i inventory/wind/inventory.ini playbooks/udm-firewall.yml --check --diff
ansible-playbook -i inventory/wind/inventory.ini playbooks/udm-firewall.yml
```

**Verify:** `nc -vz -w3 10.10.200.41 8006` OK + `terraform -chdir=…/proxmox/k8s-vms plan` works; a non-allowed port (or ICMP, now blocked under `tcp`) times out; Clients→Management hits now appear in UniFi firewall logs / Alloy.
**Rollback:** re-enable the broad rule in the UI, or `git revert` + re-run (the Gateway path to the firewall is never lost). Also update `docs/setup/headless-ops-host.md` §Network caveat.
**Effort:** S.

---

## H31 — Remove orphaned `claude-admin-temp` + scope `claude-admin`

**Goal:** delete a committed, unreferenced IAM policy granting `iam:CreateRole/AttachUserPolicy/CreatePolicyVersion/PassRole/DeleteUser` + `s3:DeleteBucket` on `Resource:*` (a `Phase6Cleanup` one-shot, confirmed by Sid + commit `87b84fe`). Also scope `claude-admin-policy`'s secrets access and bring the user into Terraform.

> **⚠ correction (worse than logged):** `claude-admin-policy.json`'s `ResourceDiscoveryReadOnly`
> Sid grants `secretsmanager:GetSecretValue/PutSecretValue/UpdateSecret` on `*` — read/overwrite
> *every* secret in the account, despite the README claiming "list/describe only."

**Steps** (account `830881980142`; run as the `homelab`/admin profile, **never** as `claude-admin`):
1. **Confirm (read-only):** `aws iam list-attached-user-policies --user-name claude-admin`; `aws iam list-entities-for-policy --policy-arn …/claude-admin-temp`; snapshot every policy version (`get-policy-version`) before changing anything.
2. **Detach + delete temp:** `aws iam detach-user-policy … --policy-arn …/claude-admin-temp` then `aws iam delete-policy …`. Remove `infra/terraform/aws/iam-policies/claude-admin-temp.json`; add a one-line "Removed (Phase 6 leftover) 2026-06-10" to the iam-policies README (mirrors its existing `~~REMOVED~~` convention).
3. **Scope secretsmanager:** in `claude-admin-policy.json`, delete `Get/Put/UpdateSecretValue` from the discovery statement (keep `ListSecrets`/`DescribeSecret`). If a real read need exists, add a separate statement scoped to `secret:ddns-*` + `secret:homeassistant-alexa-token-*` (note the `-*` random suffix). Apply via `create-policy-version --set-as-default`.
4. **Terraform-manage the user:** new stack `infra/terraform/aws/iam-users/` modeled on `ai-advisor-iam/`. `aws_iam_user.claude_admin` (+ `lifecycle { prevent_destroy = true }`), `aws_iam_policy` sourced from the JSON, `aws_iam_user_policy_attachment`. **Do NOT** add `aws_iam_access_key` (would invalidate Claude's existing key). `terraform import` the user + policy + attachment; `plan` must be clean (no destroy).

**Lockout guard:** operate only as a separate admin principal; keep a second console session open; detach-before-delete; `claude-admin` can't re-grant itself the temp policy (its perms are `terraform-*`-scoped), so removal is safe.
**Verify:** `list-attached-user-policies` shows only `claude-admin-policy`; temp ARN → `NoSuchEntity`; default version has no `secretsmanager:*SecretValue` on `*`; `terraform plan` clean; `aws iam list-policies --profile claude-admin` still works.
**Rollback:** re-create temp from snapshot (unlikely needed); `set-default-policy-version` reverts scoping instantly; `terraform state rm` backs out management without touching AWS.
**Effort:** S–M.

---

## H29 — CI AWS auth → GitHub OIDC

**Goal:** replace 22 workflows' static `AWS_ACCESS_KEY_ID/SECRET` (IAM user `terraform-homelab`) with OIDC `AssumeRoleWithWebIdentity`.

**Facts:** account `830881980142`; `terraform-homelab`'s perms come from hand-managed IAM **groups** (`terraform-core/compute/storage/integration/network`), not Terraform. 8 workflows run GitHub-hosted, 14 on `[self-hosted, lifecycle]`. Backend = S3 `terraform.wind.etherport.net`, **`use_lockfile=true` → S3-native lock (`.tflock` object), NOT DynamoDB**. No GitHub Environments → scope trust by branch ref. `ai-advisor-iam/` is the template for a TF-managed IAM stack.

**Steps:**
1. **New stack `infra/terraform/aws/github-oidc/`** (backend key `aws/github-oidc/...`). Apply it **once with the existing static keys** (chicken-and-egg), then it self-manages.
2. **OIDC provider:** `aws_iam_openid_connect_provider` url `https://token.actions.githubusercontent.com`, `client_id_list = ["sts.amazonaws.com"]`. (Thumbprint is no longer load-bearing for this well-known IdP but provide the current value.)
3. **Role `gh-actions-terraform`**, trust policy `sts:AssumeRoleWithWebIdentity` with `StringEquals aud=sts.amazonaws.com` + `StringLike sub` in `["repo:sparked-diamond/infra:ref:refs/heads/main", "repo:sparked-diamond/infra:pull_request"]`. Attach the existing `terraform-*` managed policies **by ARN** (`for_each` over the union — keeps the hand-edited docs as source of truth) + a new inline **backend policy**: `s3:Get/Put/DeleteObject` on `…/*` (covers the `.tflock`) + `s3:ListBucket`. **No DynamoDB.**
4. **Workflow edits** (×22, mechanical): add `permissions: id-token: write`; swap `configure-aws-credentials` to `role-to-assume: arn:…:role/gh-actions-terraform` (drop the two key inputs). Keep `AWS_PROFILE=""`/`-backend-config="profile="`.
5. **v1 = single role; plan/apply split is a fast-follow** (a trust-policy + 2nd-role change, no workflow rewrite).

> **⚠ self-hosted gotcha:** OIDC *works* on self-hosted runners (token via `ACTIONS_ID_TOKEN_REQUEST_*`, not IMDS) given a modern runner agent — verify the version. **Critical:** ensure the long-lived gh-runner VM has no ambient `~/.aws/credentials`/env that masks the role.

**Cutover (keys + role coexist the whole time):** apply stack → migrate one **GitHub-hosted** workflow (`terraform-s3.yml`) → verify plan+apply (CloudTrail shows `AssumeRoleWithWebIdentity`) → migrate one **self-hosted** workflow as the runner-path gate → roll the remaining ~20 in batches → **deactivate** (not delete) the key, soak one cycle → **delete** key + GH secrets. Every step before deletion is a single-file `git revert`.
**Effort:** M.

---

## H30 — SHA-pin Actions + digest-pin images (+ SOPS checksum)

**Goal:** pin the supply chain. 0/104 `uses:` SHA-pinned; 0/22 images digest-pinned; Renovate disables the docker datasource for in-house images; SOPS binary downloaded unverified.

**Steps:**
1. **Actions → SHA:** add `helpers:pinGitHubActionDigests` to `renovate.json` `extends` (+ a `matchManagers: [github-actions]` `pinDigests: true` rule). Renovate pins each `@vN` to a 40-char SHA *with a tag comment* and keeps updating it. One grouped PR.
2. **Images → digest (canonical model, M64):** add `digestReflectionPolicy: Always` to the **8 existing `ImagePolicy`** objects in `clusters/wind/image-automation/` → Flux rewrites the 17 `$imagepolicy` markers to include `@sha256:`. Add `ImageRepository`+`ImagePolicy` for the in-house images (`aws-s3-sync`, `cloudflare-ddns`, `cue`, using the `sha-<40hex>` build-tag filter) and the `$imagepolicy` markers on their consumers.
   > **⚠ correction (latent bug):** `cue-api/01-deployment.yaml` carries a `{"$imagepolicy":"flux-system:cue-api"}` marker but **no `ImagePolicy` named cue-api exists** → it floats on `:latest`. Creating the policy fixes it.
   > **⚠ ansible-runner is not a cluster workload** (it's a workflow `container:`) → pin it manually by digest in `ansible-proxmox.yml` + let Renovate track it.
3. **Re-enable Renovate** for `/sparked-diamond/` (docker datasource, `pinDigests: true`) for the workflow container + Dockerfile `FROM` digests; Flux stays the tag authority for cluster images.
4. **SOPS checksum:** new composite `.github/actions/setup-sops/action.yml` that installs a pinned version **with `sha256sum -c`** (get the real digest from the official `checksums.txt`). Rewire the **3** workflows that curl it (`terraform-drift-detection`, `terraform-aws-us-east-1`, `terraform-regional-vpn`) + add a checksum to the ansible-runner Dockerfile.

**Sequence:** setup-sops → Renovate pin → `digestReflectionPolicy` on the 8 → in-house policies → ansible-runner manual pin. Verify `flux get image policy` shows `@sha256`, no `ImagePullBackOff`, CI green.
> Confirm the running image-reflector-controller supports `digestReflectionPolicy` (ImagePolicy v1beta2) before step 2; else bump Flux first.
**Effort:** M.

---

## H33 — Backup age recipient + secrets-rotation runbook

**Goal:** one age recipient decrypts *everything*, and the private key is replicated to **three** places (mini `~/.config/sops/age/keys.txt`, GitHub `SOPS_AGE_KEY` secret, in-cluster Flux `sops-age` secret) — the real blast radius. No rotation runbook exists.

**Steps:**
1. **Generate an OFFLINE backup keypair** (on the laptop): `age-keygen -o /tmp/sops-backup-age.txt`. Store the private half **only** in 1Password (item "Homelab SOPS Age Key (BACKUP)") + printed in a safe. **Never** on the mini / GH secret / Flux secret. `rm -P` the temp file.
2. **Add the backup recipient** to all **5 creation_rules** in `.sops.yaml` *and* the ~7 nested `.sops.yaml` config files (grep for the primary recipient). Multi-recipient = OR (any one decrypts).
3. **Re-key without lockout** (primary still valid):
   ```bash
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   find . -name '*.sops.yaml' -not -name '.sops.yaml' -not -path './.git/*' -exec sops updatekeys -y {} \;
   ```
   Verify a sample lists 2 recipients + primary still decrypts; commit. No Flux/CI change (primary stays in the set).
4. **Write `docs/runbooks/secrets-rotation.md`** (format like `grafana-admin-password.md`): inventory/blast-radius table; **routine rotation** (two-phase add-new-then-remove-old, redistribute to the 3 holders, `flux reconcile`); **"mini compromised → rotate"** incident procedure — contain (power off, pull from `trusted-admin-clients`, revoke Tailscale node, pull the homelab SSH pubkey from authorized_keys) → rotate age key → re-key repo + rotate GH/Flux secrets → rotate **downstream** secrets in dependency order (AWS keys → kubeconfig/cluster-admin cert → UDM → WireGuard → Anthropic → SMTP → Ceph → Cloudflare → Twilio/hmac/advisor-ssh/barman/grafana) → `sync-secrets.py` for the 1P-managed half + `sops <file>` for the hand-edited standalone files → reconcile/redeploy → re-provision a clean mini.
5. **(Deferred) per-domain split:** separate WG key + CI key as the cheapest high-value cuts; full split is more operational surface — do later.

> **⚠ correction:** downstream secrets are in **two classes** — 1P-managed (via `homelab-ops.manifest.yaml` + `sync-secrets.py`) vs hand-edited standalone SOPS files (Anthropic, SMTP, Ceph, WG, hmac, advisor-ssh, barman, grafana). The rotation runbook must handle both paths.
**Effort:** M.

---

## H32 — Least-privilege RBAC for the remediation controller

**Goal:** the controller SA has cluster-wide `pods:delete`, `pvc:patch/delete`, `cnpg clusters:patch/update` across ALL namespaces; the "never auto CNPG/Ceph/kube-system" rule is **only** in the Python denylist + LLM prompt, not RBAC.

**Design:** ClusterRole = cluster-scoped **reads only** (`nodes`, `events`, and `get/list` of pods/workloads/pvc for diagnosis — reading anywhere is safe). All **mutating** verbs move to **namespaced Roles** bound only in the namespaces actually remediated (`dns, home-automation, monitoring, traefik, velero, metallb-system, plex, backups, flux-system, cert-manager, kube-system`). **`pvc:delete` + CNPG verbs exist ONLY in a `postgres`-namespace Role** (the one place `cnpg_recreate_replica` runs). `cnpg-system` + `rook-ceph` get **no RoleBinding** → destructive verbs unreachable there by construction.

**Steps:** rewrite `platform/kubernetes/auto-remediation/rbac.yaml` into: SA + minimal read ClusterRole/Binding + a standard namespaced Role/RoleBinding pair per target ns (no PVC verbs) + a `postgres`-only `-cnpg` Role (PVC delete + cnpg) + a `velero`-only Role (backup create). Keep manifests explicit/literal (matches the repo's flat-file style; auditable). Tighten the stale COVERAGE.md "any namespace" claim.

**Verify** with `kubectl auth can-i --as=system:serviceaccount:auto-remediation:remediation-controller`: must-be-**yes** (`delete pods -n monitoring`, `delete pvc -n postgres`, `create backups.velero.io -n velero`, `list nodes`); must-be-**no** (`delete pvc -n kube-system`, `delete pvc -n monitoring`, `delete pods -n cnpg-system`, `delete pods -n rook-ceph`, anything in a random ns). Then run a low-risk real remediation + watch controller logs for unexpected `Forbidden`.
**Stage safely:** apply the new namespaced Roles *alongside* the old ClusterRoleBinding, verify `can-i`, then remove the broad binding **last** (no deny window). Rollback = `git revert` (Flux re-applies; RBAC is instant, no redeploy).
**Effort:** M.

---

## H3 — NetworkPolicies (phased, audit-first)

**Goal:** there are zero NetworkPolicies and Cilium is allow-all. Introduce default-deny + per-tier isolation **without an outage**, observing first via Hubble (already enabled).

**Facts:** Cilium 1.18.6, **Hubble already on** (relay+UI+metrics scraped). Live inventory is `infra/kubespray/inventory/` (the `ansible/inventory/wind` paths are stale). nodelocaldns at link-local `169.254.25.10`. Flux `path: ./clusters/wind`, `prune: true`.
> **⚠ correction:** cue-api uses its **own `cue-db`** (ns `cue`), NOT the shared `postgres` cluster — the shared one's only consumers are the CNPG operator (`cnpg-system`) + **wikijs**. wireguard pods are `hostNetwork: true` → **node identity**, so podSelector CNPs don't isolate them — **exclude wireguard from enforce** in H3.

**Phase 1 — audit-only (drop nothing):** set `cilium_policy_audit_mode: true` in `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-net-cilium.yml` (apply `--tags=cilium`). Add a new `platform/kubernetes/networkpolicies/` dir (wired into `clusters/wind/kustomization.yaml`) with: the **mandatory cluster-wide allows** (DNS to host+kube-dns, host/health comms, Flux egress to GitHub/GHCR, monitoring scrape) + per-ns default-deny CNPs (harmless under audit mode). Observe 1–2 weeks via `hubble observe --verdict AUDIT` (cover all CronJobs); build allowlists from the data.

**Phase 2 — enforce per tier:** flip audit-mode off (allowlists already committed). Enforce in increasing blast-radius order: **postgres → cue → dns → traefik → monitoring** (wireguard excluded; host-firewall is a separate workstream). Example postgres isolation: only `cnpg-system` + `wikijs` (+ monitoring:9187) may reach 5432.

**Top 3 outage risks:** (1) **DNS blackhole** — nodelocaldns is link-local/host identity; the allow MUST cover `toEntities:[host,remote-node]:53` *and* the kube-dns selector, verified in audit first. (2) **Locking out Flux** — `flux-system` egress to GitHub must be allowed or you can't `git revert` your way out; keep audit-mode (ansible-applied, out-of-band) as the escape hatch. (3) **hostNetwork wireguard + monitoring blindness** — exclude wireguard; bake `monitoring` egress into every enforced ns.
**Rollback:** `git revert` (Flux `prune:true` deletes the CNP in ~1 reconcile) or `cilium_policy_audit_mode: true` / `kubectl delete cnp,ccnp --all -A`.
**Effort:** L (phased over ~2 weeks).

---

## Cross-cutting notes

- **Order independence:** H34/H31/H29/H30/H33 are independent. H32 and H3 both touch the cluster — do H32 before H3 (smaller, and H3's audit phase wants a stable RBAC baseline).
- **Everything is GitOps/IaC-reversible** except the two AWS console one-shots (delete the IAM key in H29, delete `claude-admin-temp` in H31) — both done last, after a read-only confirm + soak.
- Mark each item ✅ in `outstanding-work.md` as it lands; this doc is the durable detail.
