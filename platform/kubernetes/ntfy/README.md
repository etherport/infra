# ntfy — second critical-alert channel (M132)

A self-hosted [ntfy](https://ntfy.sh) push server so `severity=critical` alerts
reach your **phone**, not just SES email. Motivated by two near-misses where email
alone failed: ~4k alert mails eaten by a junk filter for a week (2026-05-22), and
the cairn backup failure (M138) that only surfaced when the operator noticed the
daily status email.

## Flow

```
Alertmanager (severity=critical, continue:true)
   └─ webhook → am2ntfy bridge (:8080)  ── transforms AM JSON → ntfy publish
        └─ ntfy server (:8080)  ── topic "wind-critical", urgent priority
             └─ Tailscale ingress (ntfy.tail48f596.ts.net)
                  └─ ntfy phone app (subscribed over Tailscale)
```

The critical route keeps `continue: true`, so alerts **still email** — ntfy is
additive, not a replacement.

## Pieces

| File | What |
|---|---|
| `03-deployment` + `01-config` + `02-pvc` | ntfy server, listens `:8080`, SQLite cache on a 1Gi Ceph-RBD PVC |
| `10/11/12-*` | `am2ntfy` — in-house ~50-line stdlib bridge (ntfy has no native Alertmanager parser) |
| `05-tailscale-ingress` | exposes ntfy to your Tailscale devices only — **no public endpoint** |
| AM route/receiver | in `platform/kubernetes/monitoring/03-alertmanager-config.yaml` (`ntfy-critical`) |

## One-time phone setup

1. After Flux applies, the Tailscale operator provisions the cert; find the URL:
   `kubectl -n tailscale logs deploy/operator | grep ntfy` → `https://ntfy.tail48f596.ts.net`.
2. Install the **ntfy** app, add server `https://ntfy.tail48f596.ts.net`, subscribe to
   topic **`wind-critical`**. (Tailscale must be up on the phone to receive.)
3. Test end-to-end:
   `kubectl -n ntfy exec deploy/am2ntfy -- python3 -c "import urllib.request as u; u.urlopen(u.Request('http://ntfy.ntfy.svc.cluster.local/wind-critical', data=b'test from am2ntfy', method='POST', headers={'Title':'ntfy test','Priority':'urgent','Tags':'rotating_light'}))"`

## Security

Tailnet-only (the operator ingress, `tag:cluster-ingress`) is the trust boundary —
ntfy can't sit behind Authentik forward-auth because the app subscribes
programmatically (same reason HA/Plex are ungated). No auth **within** the tanet
and a non-obvious topic name. If the tailnet ever fronts untrusted devices, enable
ntfy access tokens (`auth-default-access: deny-all` + a user/token) — a follow-up.

## Notes

- ntfy image is Renovate-pinned (`{"$imagepolicy": "flux-system:ntfy"}`).
- `sendResolved: true` on the AM receiver → you also get a RESOLVED push.
- ntfy is Flux-managed (`clusters/wind/kustomization.yaml`), not Helm.
