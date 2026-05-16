# cert-manager Wildcard + Traefik TLSStore

How the cluster issues, stores, and serves the wildcard
`*.wind.etherport.net` certificate that every Traefik IngressRoute uses
by default.

## Pieces

| Object | File | Purpose |
|--------|------|---------|
| `ClusterIssuer/letsencrypt-route53` | `platform/kubernetes/traefik/clusterissuer-letsencrypt.yaml` | Let's Encrypt issuer using DNS-01 via AWS Route53 |
| `Certificate/wildcard-wind-etherport-net` | `platform/kubernetes/traefik/certificate-wildcard.yaml` | Requests `*.wind.etherport.net` (+ apex) from the issuer; stores the result in `Secret/wildcard-wind-etherport-net-tls` in the `traefik` namespace |
| `TLSStore/default` | `platform/kubernetes/traefik/tlsstore-default.yaml` | Traefik's "default" TLSStore, set to serve the wildcard secret for any IngressRoute that doesn't specify its own cert |
| `Secret/route53-credentials` (SOPS) | `platform/kubernetes/traefik/route53-credentials.sops.yaml` | AWS access key for the issuer's DNS-01 challenge |

Renewal is automatic via cert-manager (default: 30 days before expiry).

## Verify

```bash
# Issuer is Ready
kubectl get clusterissuer letsencrypt-route53

# Certificate is Ready with a near-future renewal date
kubectl get certificate -n traefik wildcard-wind-etherport-net
kubectl describe certificate -n traefik wildcard-wind-etherport-net

# The secret cert-manager wrote
kubectl get secret -n traefik wildcard-wind-etherport-net-tls

# Traefik's default TLSStore points at it
kubectl get tlsstore -n traefik default -o yaml

# Live check
echo | openssl s_client -connect grafana.wind.etherport.net:443 \
  -servername grafana.wind.etherport.net 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

## Force a renewal

```bash
# Annotate the Certificate to trigger immediate re-issue
kubectl cert-manager renew wildcard-wind-etherport-net -n traefik

# Or, without the cert-manager kubectl plugin:
kubectl annotate certificate wildcard-wind-etherport-net -n traefik \
  cert-manager.io/issue-temporary-certificate="true" --overwrite

# Watch the new CertificateRequest
kubectl get certificaterequests -n traefik -w
```

## Rotate the Route53 credentials

1. Create a new IAM access key on the `cert-manager-route53` user.
2. Edit the SOPS secret:
   ```bash
   sops platform/kubernetes/traefik/route53-credentials.sops.yaml
   ```
3. Commit + push. Flux reconciles, cert-manager picks up the new
   secret on its next challenge.
4. Disable / delete the old access key in IAM once the next renewal
   succeeds.

## Troubleshooting

- **Certificate stuck `Ready=False`**: check the
  `CertificateRequest` and `Challenge` objects in the `traefik` ns —
  DNS-01 propagation issues usually show up there.
- **Traefik serves the default self-signed cert**: TLSStore not
  reconciled. `kubectl get tlsstore -n traefik default -o yaml` —
  `defaultCertificate.secretName` must match the cert-manager secret.
- **IngressRoute pinned to old `certResolver`**: remove the
  `tls.certResolver` field; an empty `tls: {}` lets Traefik fall
  through to the default TLSStore.

## Related

- [`platform/kubernetes/traefik/README.md`](../../platform/kubernetes/traefik/README.md)
- [`docs/architecture/overview.md`](../architecture/overview.md) — ingress / TLS row
- [`docs/runbooks/aws-private-dns.md`](aws-private-dns.md) — Route53 plumbing
