# IRSA — in-cluster workload identity for AWS (M75)

In-cluster AWS workloads get **short-lived, per-pod credentials** via
`AssumeRoleWithWebIdentity` — the self-hosted (non-EKS) **IRSA** pattern. There are
**no static AWS keys in etcd**; every workload assumes a least-priv role from a
projected ServiceAccount token. Extends [[H29]] (CI OIDC) and [[M71]] into the cluster.

TF stack: [`infra/terraform/aws/cluster-irsa/`](../../infra/terraform/aws/cluster-irsa/)
(CI-only via `terraform-cluster-irsa.yml`). The kube-apiserver issuer is persisted in
the kubespray inventory (see Architecture).

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
  The kube-apiserver runs a **single** `--service-account-issuer` = that bucket URL,
  persisted in
  [`infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml`](../../infra/kubespray/inventory/group_vars/k8s_cluster/kube_control_plane.yml)
  (`kube_kubeadm_apiserver_extra_args`, renders into `apiServer.extraArgs`). Live == IaC.
- The bucket holds the ONLY two public-read objects in the account: the discovery
  doc + the cluster's public SA signing keys (`keys.json`). **Public-read is by
  design, not a leak** — it serves the OIDC discovery + the cluster's *public* JWKS.
- **Roles (5)**: `wind-irsa-{velero,s3-sync,barman,cloudwatch-read,cue-media}` —
  trust locked to exact namespace/ServiceAccount, least-priv inline policies. See the
  [stack README](../../infra/terraform/aws/cluster-irsa/README.md) for the per-role
  scope + trusted SAs (`cue-media` is assumed by `cue:cue-api` for the cue-media S3
  bucket).
- **Injection = manual token projection (no pod-identity webhook).** Each workload
  mounts a projected SA token (audience `sts.amazonaws.com`) and sets the web-identity
  env. CNPG's operator-managed pods are covered via the Cluster CR's
  `projectedVolumeTemplate` + `env` (token at `/projected/token`).

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

## ⚠️ If you change `--service-account-issuer` (durable gotchas)

Changing the issuer is disruptive (restarts the kube-apiserver static pod on each CP)
**and** has three non-obvious ways to break the whole cluster. The `controlPlaneEndpoint`
is now the HA API VIP `k8s-api.wind.etherport.net:6443` → `10.10.201.49` (kube-vip,
ARP/L2, live since 2026-08-04 — see CLAUDE.md §3 H47), not a single CP; still roll the
CPs one at a time, **cp1 LAST** (it's the etcd leader). Persist the change in the
kubespray inventory above (never leave a hand-edit of the static manifests — a
kubespray run reverts it). Then:

1. **⚠️ Pin `--api-audiences` or you 401 ALL in-cluster auth.** `--api-audiences`
   **defaults to the FIRST `--service-account-issuer`**. Changing the first issuer
   silently changes the default accepted audience → every existing in-cluster token
   (`aud = https://kubernetes.default.svc.cluster.local`) fails audience validation →
   401 cluster-wide. **Fix:** explicitly set
   `--api-audiences=https://kubernetes.default.svc.cluster.local,sts.amazonaws.com`
   alongside the issuer (already pinned in the inventory). Validate per-CP by presenting
   a `cluster.local`-audience token to that node — **403 (RBAC) = authN OK; 401 = broken.**

2. **⚠️⚠️ Restart the Multus DaemonSet or no pod can schedule cluster-wide.** Multus
   CNI writes `/etc/cni/net.d/multus.d/multus.kubeconfig` **ONCE at pod start and never
   refreshes that token.** Any issuer change invalidates its cached token → every new
   pod's CNI add fails `multus … Unauthorized` → no pod schedules on any node (existing
   pods keep running; symptom is everything stuck `ContainerCreating`). **Fix:**
   ```bash
   kubectl -n kube-system rollout restart ds/kube-multus-ds-amd64
   ```
   The new Multus pods rewrite the kubeconfig from their current kubelet-refreshed
   token. (It was the ONLY component that bakes a token into a file at startup — the
   projected-token consumers refresh automatically. A kubespray run also restarts
   Multus, so it self-heals there.) This cost a ~7 h cluster-wide outage on 2026-06-25.

3. **Map ports container-side, and validate as the real workload.** When wiring a new
   workload into IRSA: the aws CLI v2 caches assumed creds under `$HOME/.aws`, so
   non-root pods (uid 1000, `HOME=/`) need **`HOME=/tmp`** (a root throwaway pod hides
   this — verify with the workload's actual `runAsUser`). velero's Kopia-maintenance
   Jobs do their own `AssumeRoleWithWebIdentity` → need **`AWS_REGION`** or the SDK
   builds `sts..amazonaws.com` (empty region) and DNS-fails.

**Never run kubespray except via `infra/kubespray/kubespray.sh`** (Cilium cni-owner
landmine). After any kubespray run, confirm the apiserver issuer is the bucket URL
(not the kubeadm default) and IRSA still assumes a role.

## Orphaned IAM keys — ⏳ the only remaining cleanup

The pre-IRSA secrets were NOT one shared key — they were **4 distinct dedicated
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

## Maintenance

- **Re-sync `keys.json` ONLY if `sa.key` is rotated** → copy
  `kubectl get --raw /openid/v1/jwks` over the stack's `keys.json` + re-apply.
- New AWS-using workload: add a role to `local.roles` in the stack's `main.tf`,
  apply, annotate the SA, then inject the projected token (see the standard injection
  block above) — heeding the container-vs-`$HOME`/`AWS_REGION` notes.

## Migration history

How IRSA was rolled out and cut over (Phase 1–2 publish · the disruptive Phase 3
per-CP issuer flip + single-issuer collapse · the Phase 4 per-workload migration +
gotchas · the 2026-06-25 Multus incident · rollback) is archived in
[`archive/irsa-workload-identity-migration-history.md`](archive/irsa-workload-identity-migration-history.md).
