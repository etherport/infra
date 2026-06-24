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
- ✅ **Phase 3 DONE + e2e-verified (2026-06-24):** all 3 CPs flipped
  (cp2→cp3→cp1), dual issuer (bucket primary + `cluster.local` secondary) +
  `--api-audiences` pinned. Proven end-to-end: a `velero-server` SA token
  (`aud=sts.amazonaws.com`) successfully `AssumeRoleWithWebIdentity` → `wind-irsa-velero`
  returned short-lived `ASIA…` creds. ⏳ **Persistence in IaC is a follow-up** (see
  "Persist in IaC" — DRIFT RISK).
- ⏳ **Phase 4:** pod-identity webhook + per-workload migration + secret deletion +
  shared-key rotation.

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

### Persist in IaC (kubespray) — ⚠️ DRIFT RISK, follow-up

The live change is a **hand-edit of the static pod manifest on each CP — it is NOT
in git/kubespray.** A kubespray run that regenerates `kube-apiserver.yaml` from the
kubeadm config will **WIPE it** → apiserver reverts to the single `cluster.local`
issuer → **all IRSA-migrated workloads lose AWS access.** (Low near-term risk: runs
are rare/operator-gated and no workload depends on IRSA until Phase 4 — but it MUST
be persisted as part of completing Phase 4.)

**Blocker:** this kubespray uses the kubeadm **v1beta3** config
(`roles/kubernetes/control-plane/templates/kubeadm-config.v1beta3.yaml.j2`), whose
`apiServer.extraArgs` is a **map** (one value per flag) — so it **cannot express two
`--service-account-issuer` flags**. Options, cleanest last:

1. **Collapse to a SINGLE issuer (recommended, do after Phase 4 + a token-refresh
   wait).** The secondary `cluster.local` issuer only exists so pre-flip tokens
   (`iss=cluster.local`) keep validating. Bound SA tokens refresh at ~80% TTL
   (~48 min). **>1 h after the flip (or after restarting all pods), no token carries
   `iss=cluster.local`** → safe to drop it. Then the config is single-valued and
   fits the v1beta3 map via `kube_kubeadm_apiserver_extra_args`:
   ```yaml
   kube_kubeadm_apiserver_extra_args:
     service-account-issuer: https://wind-cluster-oidc-830881980142.s3.us-west-2.amazonaws.com
     api-audiences: https://kubernetes.default.svc.cluster.local,sts.amazonaws.com
   ```
   (`api-audiences` MUST stay pinned — see the gotcha below.) Re-hand-edit the live
   manifests to single-issuer to match, OR let the next gated kubespray run apply it.
2. **`kubeadm_patches`** — kubespray can apply kubeadm patch files to the generated
   manifests; a strategic-merge/JSON6902 patch CAN add a duplicate flag. More moving
   parts; only needed if dual-issuer must persist long-term.

**Never run kubespray except via `infra/kubespray/kubespray.sh`** (Cilium cni-owner
landmine).

### ⚠️ Gotcha — pin `--api-audiences` or you break ALL in-cluster auth

`--api-audiences` was **unset** (it defaults to the FIRST `--service-account-issuer`).
Changing the first issuer to the bucket URL therefore silently changes the default
accepted audience to the bucket URL → every existing in-cluster token (`aud =
https://kubernetes.default.svc.cluster.local`) would fail audience validation → 401
cluster-wide. The fix (applied here): **explicitly set**
`--api-audiences=https://kubernetes.default.svc.cluster.local,sts.amazonaws.com`
alongside the issuer change. Validate per-CP by presenting a `cluster.local`-audience
token to that node — **403 (RBAC) = authN OK; 401 = broken.**

### Rollback

Restore `/root/kube-apiserver.yaml.pre-irsa` over the manifest on each CP (kubelet
restarts apiserver back to the single cluster.local issuer). Tokens minted with the
bucket iss become unvalidatable once the bucket issuer is removed — but those are
only the IRSA/projected tokens; default in-cluster auth uses cluster.local which is
restored. Safe.

---

## Phase 4 — pod-identity webhook + migrate workloads

1. **Deploy `amazon-eks-pod-identity-webhook`** (Flux HelmRelease or manifests). It
   mutates pods whose SA carries `eks.amazonaws.com/role-arn`: injects a projected
   SA-token volume (aud `sts.amazonaws.com`) + `AWS_ROLE_ARN` +
   `AWS_WEB_IDENTITY_TOKEN_FILE` env. (Off-EKS works; it's just a mutating webhook.)
2. **Per workload** (one at a time, verify each before the next):
   - annotate the SA: `eks.amazonaws.com/role-arn: <role_arns[workload] from TF output>`
   - drop the static-key env/secret refs:
     - **velero**: remove `credential` from the BSL + the `cloud-credentials` secret;
       the AWS plugin uses the SDK default chain (web identity).
     - **CNPG barman** (postgres + cue): set
       `barmanObjectStore.s3Credentials.inheritFromIAMRole: true`, drop the secret.
     - **s3-sync (rclone)**: set `env_auth = true` (SDK/web-identity chain), drop the
       `*-aws-backup-credentials` secret env.
     - **ai-advisor / cloudwatch-to-loki**: rely on the SDK default chain; drop the
       cloudwatch creds secret. (cloudwatch-to-loki uses the `default` SA — annotate
       it, or give it a dedicated SA first.)
   - verify the workload still reads/writes S3 / CloudWatch (run the cronjob / a
     velero backup / a CNPG backup).
3. **Delete the static-key secrets** once every consumer is migrated + verified.
4. **Rotate (NOT delete — [[H29]]) the shared `terraform-homelab` key** once nothing
   in-cluster uses it. (etcd-backup runs on the CP HOSTS, not as a pod — it is NOT an
   IRSA target; it stays a host credential, tracked under [[M71]].)

## Maintenance

- **Re-sync `keys.json` ONLY if `sa.key` is rotated** → copy
  `kubectl get --raw /openid/v1/jwks` over the stack's `keys.json` + re-apply.
- New AWS-using workload: add a role to `local.roles` in the stack's `main.tf`,
  apply, annotate the SA.
