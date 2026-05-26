# UnifiWildcardCertExpiring

Fires when `unifi_cert_sync_cert_not_after_seconds - time() < 14d` for
1 hour. Severity: critical. Auto-eligible action (in principle):
`force_cert_renewal`.

## Symptom

PrometheusRule `unifi-cert-sync / UnifiWildcardCertExpiring` firing.
The wildcard cert that `unifi-cert-sync` pushes to the UDM / UniFi
Protect / UNAS appliances is within 14 days of expiry, AND
cert-manager has not yet renewed it.

## Verified root cause(s)

- cert-manager Certificate stuck in `Issuing` due to ACME challenge
  failure (DNS-01 propagation, Cloudflare API token rotation, etc.).
- cert-manager pod down (pairs with `CertManagerDown` / `CertManagerWebhookDown`).
- The Certificate resource was modified or deleted — cert-manager
  would normally re-create on next reconcile.
- Renewal succeeded at the cert-manager layer, but `unifi-cert-sync`
  hasn't picked it up (sibling `UnifiCertSyncStale`).

## Fix history

- No prior fix in git history yet (rule exists since the initial
  unifi-cert-sync resource set; cert-manager has been reliable so
  far). Watch this space.

## Verification steps

1. Cert status from cert-manager:
   `kubectl -n traefik describe certificate wildcard-wind-etherport-net`
2. CertificateRequest:
   `kubectl -n traefik get certificaterequest --sort-by=.metadata.creationTimestamp`
3. ACME order detail (if stuck):
   `kubectl -n traefik describe order <name>`
4. cert-manager logs:
   `kubectl -n cert-manager logs deploy/cert-manager --tail=200 | grep -iE "wildcard|error"`
5. After renewal, confirm not-after advances:
   `unifi_cert_sync_cert_not_after_seconds - time()` in Prometheus
   should jump back to ~90 days.

## Advisor action guidance

- `force_cert_renewal(namespace=traefik, certificate=wildcard-wind-etherport-net)`
  — annotates the Certificate to trigger immediate re-issuance. Safe;
  cert-manager queues. Auto-eligible in principle but watch the
  confidence threshold — if a recent renewal attempt already failed,
  re-triggering won't help.
- If cert-manager itself is down, defer — restarting cert-manager
  needs to land first.
- `noop` if logs show an underlying ACME / DNS challenge issue
  (Cloudflare API token expired, DNS-01 record stale) — those need
  operator-side credential / DNS fixes.
