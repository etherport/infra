# IRSA workload-identity rollout — migration history (archived)

> 📦 **Historical — completed migrations.** This captures *how in-cluster AWS workload
> identity (M75) was rolled out and cut over*. It is **not** the live reference — for current
> state see [`../irsa-workload-identity.md`](../irsa-workload-identity.md). Kept so the rationale,
> the per-CP cutover procedure, the per-workload migration, and the dated incidents/decisions
> behind the live design are grep-able. Tracker: `docs/planning/outstanding-work.md` (M75).

All of the below is **done** (rollout completed 2026-06-24). Newest first.

The cluster-irsa TF stack README
([`infra/terraform/aws/cluster-irsa/README.md`](../../../infra/terraform/aws/cluster-irsa/README.md))
points here for the rollout phases.

---

## Rollout status (all DONE)

- ✅ **Phase 1–2 (2026-06-24):** bucket + discovery/JWKS published; IAM OIDC
  provider + 5 roles + policies applied (via CI). **Verified from the public
  internet**: discovery `issuer` matches the URL, `jwks_uri` resolves, JWKS ==
  cluster keys. Harmless until Phase 3 + 4.
- ✅ **Phase 3 (2026-06-24):** flipped all 3 CPs, then **collapsed to a SINGLE bucket
  issuer** (+ pinned `--api-audiences`) once tokens refreshed. IRSA proven end-to-end.
- ✅ **Phase 4 (2026-06-24):** all in-cluster AWS workloads migrated to IRSA via
  **manual token projection** (no webhook), static-key secrets deleted.
- ✅ **Persistence VALIDATED (2026-06-24):** live apiserver config == kubespray IaC
  (single bucket issuer), both proven working. Zero drift.

The Phase 1–2 deliverables (public OIDC bucket, IAM OIDC provider, the 5 least-priv
roles) are codified in the TF stack `infra/terraform/aws/cluster-irsa/` and remain the
current state — see the live doc + the stack README, not this file, for what they are.

---

## Phase 3 — flip `--service-account-issuer` (the DISRUPTIVE cutover)

**Why disruptive:** changing the issuer restarts the kube-apiserver static pod on
each control plane. There is **no HA API VIP** — cp1 (`10.10.201.50`) IS the
`controlPlaneEndpoint` and the address devbox kubectl hits, so restarting cp1 blips
kubectl for ~10-30 s. Workers reach the API via their local `nginx-proxy` (LBs all
3 CPs), so cp2/cp3 restarts are absorbed.

**Token-validity safety (during the flip):** added the public issuer as the **primary**
(first) `--service-account-issuer` AND kept
`https://kubernetes.default.svc.cluster.local` as a **secondary** accepted issuer. New
tokens got `iss=<bucket>`; existing tokens (`iss=cluster.local`) kept validating. The
signing key was unchanged, so the published JWKS stayed correct.

> Multiple `--service-account-issuer` flags: the FIRST is used to MINT tokens; ALL
> are accepted for validation. So all NEW tokens (every audience) carry
> `iss=<bucket>` — the standard, accepted IRSA-on-kubeadm behavior.

### Procedure (one CP at a time, cp1 LAST)

For each of **cp2 (.51), then cp3 (.52), then cp1 (.50)**:

```bash
SSH="ssh"            # M76: step-ca cert presented via ssh-config (no -i key)
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

Did NOT proceed to the next CP until the current one was healthy. **cp1 last** — a brief
kubectl blip while it restarted.

### Collapse to a single bucket issuer + persist in IaC (kubespray)

The apiserver flag was first a hand-edit of the static pod manifests (not in git),
which a kubespray run would have reverted. It was persisted in
[`infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml`](../../../infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml)
via `kube_kubeadm_apiserver_extra_args` (renders into `apiServer.extraArgs`):
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
e2e re-confirmed, token auth 403). So live == IaC == single bucket issuer.

### ⚠️⚠️ The collapse broke Multus → restarting it fixed it (2026-06-25 incident, ~7 h)

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
The new Multus pods rewrote the kubeconfig from their CURRENT kubelet-refreshed
(`iss=bucket`) mounted token. Then deleted any pods stuck `ContainerCreating` so they
re-created, and cleared stale Failed/Partial job+backup records. (This is now the durable
**RULE: whenever you change `--service-account-issuer`, restart the Multus DaemonSet** —
captured in the live doc.)

### Rollback (apiserver issuer)

Restore `/root/kube-apiserver.yaml.pre-irsa` (or `.pre-collapse`) over the manifest
on each CP; kubelet restarts the apiserver. (Workloads would then need their secrets
back — restore the SOPS files from git history.)

---

## Phase 4 — migrate workloads (manual token projection, completed 2026-06-24)

**No pod-identity webhook.** Chosen to avoid a cluster-wide mutating admission
webhook + its serving cert; instead each workload **manually projects** an SA token
and sets the web-identity env. (CNPG's operator-managed pods are covered via the
Cluster CR's `projectedVolumeTemplate` + `env`, which mount at `/projected`.) This
manual-projection injection pattern is the current state — see the live doc for the
standard injection block to copy when adding a new workload.

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

### Phase 4 gotchas (all hit + fixed during the migration)

These are durable behaviours of the manual-projection pattern — kept here as the
record of where they bit; the live doc's injection guidance reflects them.

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
