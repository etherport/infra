# cert-manager DNS-01 migration: Route53 → Cloudflare

## Why this exists

When the etherport.net Route53 hosted zone was deleted on 2026-05-27
(as part of the Route53 → Cloudflare DNS migration), both
ClusterIssuers in `platform/kubernetes/traefik/` lost the ability to
solve ACME DNS-01 challenges. Any cert renewal triggered after that
point fails with `NoSuchHostedZone`.

The next shortlived-profile wildcard renewal is scheduled for
**2026-05-30** (cert expires 2026-06-01). Without this migration that
renewal will fail and *.wind.etherport.net TLS breaks ~2 days later.

The classic-profile RSA wildcard (used by UniFi OS) renews mid-July, so
it has more runway, but it's broken by the same root cause.

This runbook captures the cutover.

## What's already landed (autonomously, 2026-05-27)

- `clusterissuer-letsencrypt.yaml` + `clusterissuer-letsencrypt-classic.yaml`
  in `platform/kubernetes/traefik/` flipped from `route53` to
  `cloudflare` DNS-01 solver. They reference a Secret named
  `cloudflare-credentials` in the `cert-manager` namespace.
- `platform/kubernetes/cert-manager-issuer/` directory created with
  `kustomization.yaml` + a `cloudflare-credentials.sops.yaml.template`.
  The directory is wired into Flux via `clusters/wind/kustomization.yaml`.
- The template's resource line in `kustomization.yaml` is COMMENTED OUT
  to keep Flux reconciliation green until the real secret lands.

## What the user needs to do (~5 min)

### 1. Get a Cloudflare API token

Either reuse the existing `cloudflare-tf-token` (already has
Zone:DNS:Edit on etherport.net) by reading it from 1Password, OR
create a new dedicated token:

  dash.cloudflare.com → My Profile → API Tokens → Create Token
    Permissions:
      Zone — Zone     — Read
      Zone — DNS      — Edit
    Zone Resources:
      Include — Specific zone — etherport.net
    Save the token output (32-char hex).

### 2. Create the encrypted secret

```bash
cd platform/kubernetes/cert-manager-issuer
cp cloudflare-credentials.sops.yaml.template cloudflare-credentials.sops.yaml
sops cloudflare-credentials.sops.yaml
# In the editor: replace REPLACE_WITH_CF_TOKEN with the token.
# Save + quit; SOPS re-encrypts.
```

### 3. Uncomment the resource line in kustomization.yaml

```bash
sed -i '' 's|^  # - cloudflare-credentials.sops.yaml$|  - cloudflare-credentials.sops.yaml|' \
  platform/kubernetes/cert-manager-issuer/kustomization.yaml
```

### 4. Commit + push

```bash
git add platform/kubernetes/cert-manager-issuer/
git commit -m "cert-manager: enable Cloudflare DNS-01 secret"
git push
```

### 5. Wait for Flux + verify

```bash
# Flux reconcile (~30s typical):
flux reconcile kustomization flux-system

# Verify the secret landed in cert-manager namespace:
kubectl get secret -n cert-manager cloudflare-credentials -o jsonpath='{.metadata.labels}{"\n"}'
# Should show kustomize.toolkit.fluxcd.io labels.

# Verify ClusterIssuer is Ready:
kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.conditions[?(@.type=="Ready")]}{"\n"}'
```

### 6. Force a renewal to validate end-to-end (recommended)

Delete the current CertificateRequest so cert-manager re-issues
immediately, rather than waiting until the natural renewal window:

```bash
kubectl -n traefik delete certificaterequest \
  $(kubectl -n traefik get certificaterequest \
    -l cert-manager.io/certificate-name=wildcard-wind-etherport-net \
    -o name | tail -1)
```

Watch the new request progress:

```bash
kubectl -n traefik get certificaterequest -w
# It moves: Pending → Approved → Ready in 30–90s typical.
# If it sticks on Pending, kubectl describe the CR + check the
# cert-manager pod logs:
kubectl -n cert-manager logs -l app=cert-manager --tail=50 | grep -E 'cloudflare|Solving|Presented'
```

### 7. Clean up Route53 leftovers (after successful renewal)

Once the new wildcard cert is issued and serving, the Route53 path is
fully dead. Cleanup steps:

```bash
# Delete the AWS access key for the cert-manager-route53 IAM user
# (you'll find the key ID in 1Password or in the existing SOPS secret):
aws iam delete-access-key --user-name cert-manager-route53 --access-key-id AKIA...

# Delete the IAM user itself (no longer referenced):
aws iam delete-user --user-name cert-manager-route53

# Drop the obsolete SOPS file:
git rm platform/kubernetes/traefik/route53-credentials.sops.yaml
# Remove its line from platform/kubernetes/traefik/kustomization.yaml.

# Delete the live secrets (Flux pruning may take a cycle):
kubectl -n traefik delete secret route53-credentials
kubectl -n cert-manager delete secret route53-credentials
```

## Why the new directory instead of dropping the secret into traefik/

`platform/kubernetes/traefik/kustomization.yaml` sets
`namespace: traefik` at the Kustomization level, which Kustomize uses
as a transformer that overrides any per-resource `metadata.namespace`.
A secret targeting `cert-manager` namespace placed in that
kustomization would silently be reassigned to `traefik` — and the
ClusterIssuer secret lookup defaults to the cert-manager namespace, so
the issuer would fail with "secret not found".

The dedicated `cert-manager-issuer/` directory has no namespace
transformer, so resources keep their declared namespace.

## Why the template-then-uncomment pattern

It lets the user commit the migration code (this PR) and the secret
scaffolding (this dir) BEFORE the actual token paste. Until the user
runs the steps above, Flux reconciles a no-op directory — no churn,
no failures. The cutover is a single-line uncomment + commit.
