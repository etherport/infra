# IRSA — in-cluster workload identity for AWS (M75)

Short-lived, per-pod AWS credentials via `AssumeRoleWithWebIdentity`, replacing the
long-lived static IAM keys that in-cluster workloads carried in K8s Secrets/etcd
(one shared key was copied across ~13 secrets in 8 namespaces). Self-hosted /
non-EKS IRSA. Extends [[H29]] (CI OIDC) and [[M71]] into the cluster.

TF stack: [`infra/terraform/aws/cluster-irsa/`](../../infra/terraform/aws/cluster-irsa/).

## Architecture

```
pod (projected SA token, aud=sts.amazonaws.com, iss=<bucket-url>)
  └─ AWS SDK AssumeRoleWithWebIdentity
       └─ STS fetches  https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com
                        /.well-known/openid-configuration  +  /keys.json
            validates token sig against the cluster's published JWKS
       └─ returns short-lived creds for  wind-irsa-<workload>  role (least-priv)
```

- **Issuer** = the public S3 bucket URL `https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com`
  (dotless bucket → single-label host → valid under `*.s3.us-west-2.amazonaws.com`).
- The bucket holds the ONLY two public-read objects in the account: the discovery
  doc + the cluster's public SA signing keys (`keys.json`).
- **Roles**: `wind-irsa-{velero,s3-sync,barman,cloudwatch-read}`, trust locked to
  exact namespace/ServiceAccount, least-priv inline policies. See the stack README.

## Status

- ✅ **Phase 1–2 (2026-06-24):** bucket + discovery/JWKS published; IAM OIDC
  provider + 4 roles + policies applied (via CI). **Verified from the public
  internet**: discovery `issuer` matches the URL, `jwks_uri` resolves, JWKS ==
  cluster keys. Harmless until Phase 3 + 4.
- ✅ **Phase 3 DONE + e2e-verified (2026-06-24):** flipped all 3 CPs, then
  **collapsed to a SINGLE bucket issuer** (+ pinned `--api-audiences`) once tokens
  refreshed — see Phase 3 + Persistence below. IRSA proven end-to-end.
- ✅ **Phase 4 DONE (2026-06-24):** all in-cluster AWS workloads migrated to IRSA
  via **manual token projection** (no webhook), static-key secrets deleted. Details
  + per-workload gotchas below.
- ✅ **Persistence VALIDATED (2026-06-24):** live apiserver config == kubespray IaC
  (single bucket issuer), both proven working. Zero drift.
- ⏳ **Only follow-up:** deactivate/remove the 4 now-orphaned dedicated IAM access
  keys (their key material lingers in git history + AWS). See "Orphaned IAM keys".

---

## Phase 3 — flip `--service-account-issuer` (DISRUPTIVE, do in a focused window)

**Why disruptive:** changing the issuer restarts the kube-apiserver static pod on
each control plane. There is **no HA API VIP** — cp1 (`10.10.201.50`) IS the
`controlPlaneEndpoint` and the address devbox kubectl hits, so restarting cp1 blips
kubectl for ~10-30 s. Workers reach the API via their local `nginx-proxy` (LBs all
3 CPs), so cp2/cp3 restarts are absorbed.

**Token-validity safety:** add the public issuer as the **primary** (first)
`--service-account-issuer` AND keep `https://kubernetes.default.svc.cluster.local`
as a **secondary** accepted issuer. New tokens get `iss=<bucket>`; existing tokens
(`iss=cluster.local`) keep validating. The signing key is unchanged, so the
published JWKS stays correct.

> Multiple `--service-account-issuer` flags: the FIRST is used to MINT tokens; ALL
> are accepted for validation. So all NEW tokens (every audience) will carry
> `iss=<bucket>` — this is the standard, accepted IRSA-on-kubeadm behavior.

### Procedure (one CP at a time, cp1 LAST)

For each of **cp2 (.51), then cp3 (.52), then cp1 (.50)**:

```bash
K=~/.ssh/id_ed25519_homelab
SSH="ssh -i $K -o IdentitiesOnly=yes"
NODE=10.10.201.51    # then .52, then .50

# 0. backup the manifest
$SSH ubuntu@$NODE 'sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.pre-irsa'

# 1. edit /etc/kubernetes/manifests/kube-apiserver.yaml: REPLACE the single
#    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
#    with TWO lines, the public issuer FIRST:
#      - --service-account-issuer=https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com
#      - --service-account-issuer=https://kubernetes.default.svc.cluster.local
#    (kubelet auto-restarts the static pod on save.)

# 2. wait for the apiserver to come back, then VALIDATE before touching the next CP:
kubectl get --raw='/readyz?verbose' | tail -3        # apiserver healthy
kubectl -n kube-system get pods | grep kube-apiserver # all Running
# fresh token carries the new iss:
kubectl create token default -n default --audience=sts.amazonaws.com \
  | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | grep -E '"iss"|"aud"'
#   → "iss": "https://wind-cluster-oidc-...amazonaws.com", "aud": ["sts.amazonaws.com"]
# existing workloads still authing (TokenReview accepts old iss): spot-check a few pods.
```

Do NOT proceed to the next CP until the current one is healthy. **cp1 last** —
expect a brief kubectl blip while it restarts.

### Validate the full chain (after all 3 CPs)

```bash
# A real pod token should now AssumeRoleWithWebIdentity. Quick e2e with the aws CLI
# in a throwaway pod annotated for a role (or wait for Phase 4 migration to prove it).
```

### Persist in IaC (kubespray) — ✅ DONE (live == IaC, validated)

The apiserver flag was first a hand-edit of the static pod manifests (not in git),
which a kubespray run would have reverted. Now persisted:
[`infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml`](../../infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml)
sets `kube_kubeadm_apiserver_extra_args` (renders into `apiServer.extraArgs`):
```yaml
kube_kubeadm_apiserver_extra_args:
  service-account-issuer: "https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com"
  api-audiences: "https://kubernetes.default.svc.cluster.local,sts.amazonaws.com"
```
kubeadm **v1beta3** `extraArgs` is a map (one value per flag) → it can express only a
**single** `service-account-issuer`. So the initial DUAL-issuer cutover (bucket
primary + `cluster.local` secondary, for token-validity safety during the flip) was
**collapsed to the single bucket issuer** once all bound SA tokens had re-minted with
`iss=<bucket>` (1 h TTL, refresh ~48 m). **The live manifests were re-edited to single
issuer to MATCH this IaC and validated in production** (all 3 CPs single issuer, IRSA
e2e re-confirmed, token auth 403). So live == IaC == single bucket issuer — a future
gated kubespray run reproduces the working config, no drift.

**Never run kubespray except via `infra/kubespray/kubespray.sh`** (Cilium cni-owner
landmine). After any kubespray run, confirm the apiserver issuer is the bucket URL
(not the kubeadm default) and IRSA still assumes a role.

### ⚠️⚠️ Changing the issuer breaks Multus → restart it (2026-06-25 incident)

**Multus CNI writes `/etc/cni/net.d/multus.d/multus.kubeconfig` ONCE at pod start and
never refreshes that token.** The collapse to single issuer (dropping `cluster.local`)
invalidated Multus's cached `iss=cluster.local` token → every new pod's CNI add failed
`multus … error waiting for pod: Unauthorized` → **no pod could schedule on any node
for ~7 h** (existing pods kept running; the symptom was cronjobs/backups stuck in
`ContainerCreating`, cascading into a storm of KubeJobFailed / KubePodNotReady /
VeleroBackupPartial / stale-metric alerts and AI-advisor traffic).

**Fix (no apiserver change needed):**
```bash
kubectl -n kube-system rollout restart ds/kube-multus-ds-amd64
```
The new Multus pods rewrite the kubeconfig from their CURRENT kubelet-refreshed
(`iss=bucket`) mounted token. Then delete any pods stuck `ContainerCreating` so they
re-create, and clear stale Failed/Partial job+backup records.

**RULE: whenever you change `--service-account-issuer`, restart the Multus DaemonSet**
(it was the ONLY component that bakes a token into a file at startup — no other auth
errors were observed, the projected-token consumers refresh automatically). A future
kubespray run also restarts Multus, so it self-heals there. **More robust option if
issuer changes become routine:** keep `cluster.local` as a permanent SECONDARY accepted
issuer (dual-issuer) so this class of break can't occur — but that needs `kubeadm_patches`
to persist (v1beta3 extraArgs is a single-value map; bucket must stay FIRST = the minting
issuer, so append cluster.local via a patch).

### ⚠️ Gotcha — pin `--api-audiences` or you break ALL in-cluster auth

`--api-audiences` was **unset** (it defaults to the FIRST `--service-account-issuer`).
Changing the first issuer to the bucket URL therefore silently changes the default
accepted audience to the bucket URL → every existing in-cluster token (`aud =
https://kubernetes.default.svc.cluster.local`) would fail audience validation → 401
cluster-wide. The fix (applied here): **explicitly set**
`--api-audiences=https://kubernetes.default.svc.cluster.local,sts.amazonaws.com`
alongside the issuer change. Validate per-CP by presenting a `cluster.local`-audience
token to that node — **403 (RBAC) = authN OK; 401 = broken.**

---

## Phase 4 — migrate workloads (manual token projection — ✅ DONE 2026-06-24)

**No pod-identity webhook.** Chosen to avoid a cluster-wide mutating admission
webhook + its serving cert; instead each workload **manually projects** an SA token
and sets the web-identity env. (CNPG's operator-managed pods are covered via the
Cluster CR's `projectedVolumeTemplate` + `env`, which mount at `/projected`.)

**The standard injection** (workloads where you control the pod spec):
```yaml
# container env:
- { name: AWS_ROLE_ARN,                value: "arn:aws:iam::830881980142:role/wind-irsa-<role>" }
- { name: AWS_WEB_IDENTITY_TOKEN_FILE, value: "/var/run/secrets/eks.amazonaws.com/serviceaccount/token" }
# container volumeMount:
- { name: aws-iam-token, mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount, readOnly: true }
# pod volume:
- name: aws-iam-token
  projected:
    sources: [ { serviceAccountToken: { audience: sts.amazonaws.com, expirationSeconds: 3600, path: token } } ]
```

**Migrated workloads → role** (all verified — backup completed / STS assume / S3 list):
| Workload (ns) | SA | role | mechanism |
|---|---|---|---|
| velero server + node-agent (velero) | velero-server | velero | chart `configuration.extraEnvVars` (→ both pods) + `extraVolumes`/`extraVolumeMounts` + `nodeAgent.extraVolumes/Mounts`; `credentials.useSecret: false` |
| s3-sync ×7 + approval-server + validation-job + daily-report + unifi-backup (backups) | s3-sync\* / unifi-backup / daily-report | s3-sync | env + projected vol; dropped `aws-backup-credentials` envFrom |
| CNPG postgres-cluster (postgres) + cue-db (cue) | postgres-cluster / cue-db | barman | Cluster CR `env` + `projectedVolumeTemplate` (token at **`/projected/token`**) + `s3Credentials.inheritFromIAMRole: true` |
| ai-advisor (auto-remediation) | remediation-controller | cloudwatch-read | deployment env + projected vol; controller `_get_logs_client()` guard now accepts web identity |
| cloudwatch-to-loki (cloudwatch-to-loki) | cloudwatch-to-loki | cloudwatch-read | cronjob env + projected vol |

Then the static-key secrets were removed (SOPS files + kustomization entries →
Flux prune; velero `cloud-credentials` + an orphan velero-restored
`aws-backup-credentials` deleted live). **No static AWS keys remain in etcd.**

### Phase 4 gotchas (all hit + fixed)
- **velero double-env (Helm `$setElementOrder` UpgradeFailed):** the chart renders
  `configuration.extraEnvVars` into BOTH server AND node-agent → don't ALSO set
  `nodeAgent.extraEnvVars` (duplicates the vars). Put env only in
  `configuration.extraEnvVars`; node-agent needs only its own `extraVolumes/Mounts`.
- **velero Kopia maintenance STS region:** the repo-maintenance Jobs inherit velero's
  env and do their OWN `AssumeRoleWithWebIdentity` → need **`AWS_REGION`** or the SDK
  builds `sts..amazonaws.com` (empty region) → DNS fail. The BSL region config does
  NOT cover this. Set `AWS_REGION`/`AWS_DEFAULT_REGION` in `configuration.extraEnvVars`.
- **aws CLI v2 + non-root `$HOME`:** the s3-sync/approval/unifi/daily-report/validation
  pods run as uid 1000 with HOME=/ (unwritable); the CLI caches assumed creds under
  `$HOME/.aws` → `Permission denied: '/.aws'`. Set **`HOME=/tmp`**. (boto3 — ai-advisor,
  cloudwatch-to-loki — and the Go SDK — velero, CNPG — don't disk-cache, unaffected.)
- **Test as the REAL security context:** a root throwaway pod hides the `$HOME` issue;
  verify with the workload's actual `runAsUser`.

### Orphaned IAM keys — ⏳ the only remaining cleanup
The migrated secrets were NOT one shared key — they were **4 distinct dedicated
per-workload IAM users** (the `AKIA4C5DM33X` prefix is just the account-ID prefix
shared by every key in account 830881980142). All are now unused in-cluster, but
their key material lingers in **git history** (the deleted SOPS files) + is still
**Active in AWS**, so finish the teardown:
| Access key | IAM user | TF-managed? |
|---|---|---|
| `…G2SF43X2` | ai-advisor-readonly | `infra/terraform/aws/ai-advisor-iam` (`aws_iam_access_key.ai_advisor`) |
| `…ESUYDI7E` | barman-postgres | `infra/terraform/aws/s3` (`aws_iam_access_key.postgres_barman`) |
| `…L7Y4X5BF` | velero (user TBD) | find the stack/user |
| `…OVJ3J4H7` | kubernetes-s3-backup (s3-sync) | find the stack/user |
**Do:** remove the `aws_iam_access_key` resources (+ their `output`s + any SOPS
render refs) from the owning TF stacks and apply via CI → deletes the keys cleanly.
For the 2 non-TF users, locate where they're defined first. **NB this is NOT the
H29 `terraform-homelab` key** (which is shared with the local homelab profile/CI —
rotate-only, never delete). **etcd-backup runs on the CP HOSTS (systemd), not a pod
— it is NOT an IRSA target;** it keeps a host credential, tracked under [[M71]].

> **SES SMTP exception:** `alertmanager-smtp-*` + `ai-advisor-smtp` secrets hold
> AKIA-looking values — those are SES **SMTP usernames** (the SMTP protocol needs a
> static username/password derived from an IAM key; it can't use web identity). They
> are correctly out of IRSA scope and stay static.

### Rollback (apiserver issuer)
Restore `/root/kube-apiserver.yaml.pre-irsa` (or `.pre-collapse`) over the manifest
on each CP; kubelet restarts the apiserver. (Workloads would then need their secrets
back — restore the SOPS files from git history.)

## Maintenance

- **Re-sync `keys.json` ONLY if `sa.key` is rotated** → copy
  `kubectl get --raw /openid/v1/jwks` over the stack's `keys.json` + re-apply.
- New AWS-using workload: add a role to `local.roles` in the stack's `main.tf`,
  apply, annotate the SA.
