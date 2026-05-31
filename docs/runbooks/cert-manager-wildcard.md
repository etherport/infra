# cert-manager wildcard cert: renewal + rotation

How the `*.wind.etherport.net` wildcard is issued, when it renews, and
the recovery procedures for the failure modes worth practising before
they bite during a real outage.

## Architecture

We run **two parallel wildcard certs** for the same set of names, with
two ACME profiles, because one consumer (UniFi OS unifi-core) refuses
the modern shortlived profile.

```
                 Let's Encrypt (acme-v02.api.letsencrypt.org)
                                       │
        ┌──────────────────────────────┴────────────────────────────┐
        │  shortlived profile                    classic profile     │
        │  (CN omitted, 6-day validity)          (CN included, 90d)  │
        └──────────────────────────────┬────────────────────────────┘
                                       │ shared ACME account
                                       │ (letsencrypt-prod-account-key)
                ┌──────────────────────┴────────────────────────┐
                ▼                                               ▼
   ClusterIssuer: letsencrypt-prod               ClusterIssuer: letsencrypt-prod-classic
   solver: dns01 / Route53                       solver: dns01 / Route53
   ↓                                             ↓
   Certificate: wildcard-wind-etherport-net      Certificate: wildcard-wind-etherport-net-rsa
   key: ECDSA P-256                              key: RSA 2048
   secret: wildcard-wind-etherport-net-tls       secret: wildcard-wind-etherport-net-rsa-tls
   ↓                                             ↓
   Consumer: Traefik (all *.wind.etherport.net   Consumer: unifi-cert-sync CronJob →
   ingress goes through this — served via        UDM Pro Max, Protect, UNAS Pro
   the TLSStore/default catch-all)
```

**Files of record:**

| Object | File |
|---|---|
| ECDSA cert | `platform/kubernetes/traefik/certificate-wildcard.yaml` |
| RSA cert | `platform/kubernetes/traefik/certificate-wildcard-rsa.yaml` |
| shortlived ClusterIssuer | `platform/kubernetes/traefik/clusterissuer-letsencrypt.yaml` |
| classic ClusterIssuer | `platform/kubernetes/traefik/clusterissuer-letsencrypt-classic.yaml` |
| Route53 creds (SOPS) | `platform/kubernetes/traefik/route53-credentials.sops.yaml` |
| Traefik default TLSStore | `platform/kubernetes/traefik/tlsstore-default.yaml` |
| cert-manager Helm values | `platform/kubernetes/cert-manager/values.yaml` |
| UniFi cert push CronJob | `platform/kubernetes/unifi-cert-sync/` |

**Why the asymmetry exists:** unifi-core (the UniFi OS web service on
UDM Pro Max, UniFi Protect, UNAS Pro) silently rejects ECDSA certs
*and* certs without CN in Subject — falling back to a
`CN=unifi.local` self-signed cert. So unifi-cert-sync gets its own
RSA+classic cert. Traefik gets the faster ECDSA+shortlived cert
because nothing on the K8s side cares about CN-in-Subject and shorter
validity means less to revoke if a key ever leaks.

## Automatic renewal

cert-manager handles renewal without intervention:

- **ECDSA / shortlived** — 6-day validity. cert-manager renews when
  cert age crosses 2/3 of validity (~day 4). DNS-01 challenge against
  Route53 takes ~30s once propagation settles.
- **RSA / classic** — 90-day validity. cert-manager renews at day 60.
- **unifi-cert-sync CronJob** — runs daily; pushes the current RSA
  cert to UniFi OS endpoints when their fingerprint differs from the
  cluster secret. Idempotent.

**Healthy state, day-to-day:**

```
$ kubectl -n traefik get certificate
NAME                                READY   SECRET                                  AGE
wildcard-wind-etherport-net         True    wildcard-wind-etherport-net-tls         <6d
wildcard-wind-etherport-net-rsa     True    wildcard-wind-etherport-net-rsa-tls     <90d
```

If `READY` is False for more than 10 minutes, see [Failure modes](#failure-modes) below.

## Verify

```bash
# Issuers Ready
kubectl get clusterissuer letsencrypt-prod letsencrypt-prod-classic

# Certificate state + renewal time
kubectl -n traefik get certificate -o wide
kubectl -n traefik describe certificate wildcard-wind-etherport-net

# Traefik default TLSStore wired to the ECDSA secret
kubectl -n traefik get tlsstore default -o jsonpath='{.spec.defaultCertificate.secretName}'

# Live check
echo | openssl s_client -connect grafana.wind.etherport.net:443 \
  -servername grafana.wind.etherport.net 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# UniFi-side check (replace IP with the UDM's mgmt VLAN IP)
echo | openssl s_client -connect 10.10.200.1:443 -servername unifi.wind.etherport.net 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

## Manual rotation procedures

### Force-renew the ECDSA cert (Traefik)

```
kubectl cert-manager renew wildcard-wind-etherport-net -n traefik
# or, without the plugin:
kubectl -n traefik annotate certificate wildcard-wind-etherport-net \
    cert-manager.io/issue-temporary-certificate="true" --overwrite
kubectl -n traefik get certificaterequests -w
```

Traefik picks up the new secret on its next reconcile — no restart
needed.

### Force-renew the RSA cert (UniFi)

```
kubectl cert-manager renew wildcard-wind-etherport-net-rsa -n traefik
kubectl -n traefik wait --for=condition=Ready \
    certificate/wildcard-wind-etherport-net-rsa --timeout=180s
# Push to UniFi now instead of waiting for the next daily run
kubectl -n unifi-cert-sync create job manual-sync-$(date +%s) \
    --from=cronjob/unifi-cert-sync
```

### Rotate the Cloudflare credentials

The DNS-01 solver moved from Route53 to Cloudflare on 2026-05-27 (the
etherport.net Route53 zone was deleted as part of the CF migration).
See `docs/runbooks/archive/cert-manager-dns01-cf-migration.md` for the
historical cutover.

The issuer now uses a CF API token stored in
`platform/kubernetes/cert-manager-issuer/cloudflare-credentials.sops.yaml`.

1. Create a new CF API token (CF dashboard → My Profile → API Tokens).
   Scopes:
     Zone — Zone — Read
     Zone — DNS  — Edit
   Zone resources: include — specific zone — etherport.net
2. Edit the SOPS file:
   ```
   sops platform/kubernetes/cert-manager-issuer/cloudflare-credentials.sops.yaml
   ```
3. Replace the `api-token` value with the new token. Save + quit;
   SOPS re-encrypts on close.
4. Commit + push. Flux reconciles; cert-manager picks up the new
   secret on the next DNS-01 challenge (or force-renew to test
   immediately — see "Force a renewal" above).
5. Revoke the old token in CF dashboard once the new one is verified.

### Historical: rotate the Route53 credentials (pre-2026-05-27)

Kept here as breadcrumb in case the migration is ever reversed. The
issuer USED to read an AWS access key from
`platform/kubernetes/traefik/route53-credentials.sops.yaml` for an
IAM user `cert-manager-route53` (managed by the now-deleted
`infra/terraform/aws/route53` module — find iam.tf in git history if
needed).

### Force-regenerate the ACME account key

If `letsencrypt-prod-account-key` is suspected compromised: both
ClusterIssuers share it, so rotating once covers both.

```
kubectl -n cert-manager delete secret letsencrypt-prod-account-key
kubectl apply -f platform/kubernetes/traefik/clusterissuer-letsencrypt.yaml
kubectl apply -f platform/kubernetes/traefik/clusterissuer-letsencrypt-classic.yaml
```

The new account registers with the same contact email. Existing certs
continue to validate against their issued chains until they renew, at
which point they re-issue under the new account.

## Failure modes

### `READY: False, reason: Failed`, message mentions `dns01`

Most common cause: the `route53-credentials` secret is missing or its
IAM policy doesn't allow `route53:ChangeResourceRecordSets` for the
hosted zone.

Check:
```
kubectl -n traefik get secret route53-credentials -o yaml | grep -c "AWS_ACCESS_KEY_ID"
# H19 raised the terraform-dns IAM policy to v3 — that's the floor.
```

Fix: re-create from the SOPS source if missing, or re-attach the IAM
policy if it was reverted.

### `READY: False, reason: Failed`, message mentions `urn:ietf:params:acme:error:rateLimited`

Either the per-domain duplicate-cert limit (5/week for the **exact same**
SAN set) or the per-account issuance limit (50/week). We hit this if a
loop misconfiguration repeatedly deletes+recreates the Certificate.

Recovery:
- Stop the loop (find what's deleting the Certificate — usually a bad
  kustomization re-apply pattern or a manual `kubectl delete` in a
  script).
- Wait until the rolling 7-day window clears.
- The two existing issued certs remain valid until natural expiry —
  Traefik / UniFi keep serving the old cert.

### Traefik serves a stale or self-signed cert despite `READY: True`

Traefik watches the secret, so this only happens if the secret name
changed or the `TLSStore/default` got rewritten. Verify both:

```
kubectl -n traefik get tlsstore default -o yaml | grep secretName
# expected: wildcard-wind-etherport-net-tls

kubectl -n traefik get secret wildcard-wind-etherport-net-tls \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | \
    openssl x509 -noout -subject -dates
```

If the secret content is fresh but Traefik still serves stale, force
a Traefik rollout:

```
kubectl -n traefik rollout restart deployment/traefik
```

### IngressRoute serves the wrong cert

If an individual IngressRoute pins `tls.certResolver` or sets its own
`tls.secretName`, it bypasses the default TLSStore. Remove those
fields — `tls: {}` is enough to inherit the wildcard via
TLSStore/default.

### unifi-cert-sync logs `405` or `401` against UniFi OS

The UDM rotated its admin password or the script's stored session/CSRF
expired. The script reauths from the `tf-admin` 1Password item — fix
is on the UniFi side (rotate via UI, then update the 1P item, then
`kubectl -n unifi-cert-sync delete configmap unifi-session` to force a
fresh login on next run).

### `kubectl -n traefik describe certificate` shows correct state but the secret isn't updating

cert-manager controller may have hit a transient API server hiccup:

```
kubectl -n cert-manager rollout restart deployment/cert-manager
```

The next reconcile in ~30s should re-sync.

## What to NOT do

- **Don't delete `letsencrypt-prod-account-key`** unless you're
  intentionally rotating it. Deleting it re-registers a new ACME
  account, which counts as a new issuance for rate-limit purposes; if
  the LE rate limit is already hot, this can block recovery.
- **Don't add SAN entries to the wildcard.** Each unique SAN set is a
  separate cert in LE's accounting. The wildcard already covers
  everything under `*.wind.etherport.net`; adding e.g. `etherport.net`
  bare means a new cert is issued (and the duplicate-cert detection
  triggers because the SAN set differs).
- **Don't switch the RSA cert to ECDSA** trying to "modernize." UniFi
  OS will silently reject and revert to its self-signed default.
- **Don't put `tls.certResolver` or per-route `tls.secretName` on a
  new IngressRoute** unless you have a specific reason — it bypasses
  the wildcard wiring. `tls: {}` is enough.

## Related

- [`platform/kubernetes/traefik/README.md`](../../platform/kubernetes/traefik/README.md)
- [`docs/architecture/overview.md`](../architecture/overview.md) — ingress / TLS row
- [`docs/runbooks/archive/aws-private-dns.md`](aws-private-dns.md) — Route53 plumbing
- [`platform/kubernetes/unifi-cert-sync/README.md`](../../platform/kubernetes/unifi-cert-sync/README.md) — UniFi push job

## Last reviewed

2026-05-22 — captured the shortlived / classic profile split, the
unifi-cert-sync sidecar dependency, and the LE rate-limit gotcha.
Supersedes the prior thinner version of this doc. Next review when
cert-manager bumps to v1.20+ (CRD upgrade required, see
`platform/kubernetes/cert-manager/values.yaml` `crds.enabled: false`).
