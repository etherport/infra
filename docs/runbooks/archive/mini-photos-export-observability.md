# Mac mini photos-export backup — observability (cluster side)

> ⚠️ **SUPERSEDED 2026-06-26 by cairn (M103).** This describes the old `photos_export_*` metric
> schema. Backups now emit the **cairn label schema** (`cairn_backup_*{job=...}` + `cairn_photos_*`);
> the dashboards/alerts were rewritten accordingly. See [`cairn-deployment.md`](cairn-deployment.md)
> and the cairn repo README §5 (metrics). Kept for historical context.

The Mac mini (`10.10.202.101`, macOS, **off-cluster**) runs the iCloud photos
backup pipeline. It pushes **metrics** to the cluster Pushgateway after each run
and ships **logs** to Loki via Grafana Alloy. This is the **cluster-side** wiring
that receives both. (The mini-side launchd jobs / Alloy config live on the mini,
not in this repo.) Shipped 2026-06-22 ([[M100]]).

## Endpoints (internal, Traefik)
| Host (Technitium → `10.10.201.70`) | → Service | Use |
|---|---|---|
| `pushgateway.wind.etherport.net` | `svc/pushgateway:9091` (monitoring) | metrics push |
| `loki.wind.etherport.net` | `svc/loki:3100` (monitoring) | Alloy log push (`/loki/api/v1/push`) |

- IngressRoutes: `platform/kubernetes/monitoring/08-mini-backup-ingressroutes.yaml`
  (`websecure`, wildcard `*.wind.etherport.net` cert). **The mini must use
  `https://`** — the `web`:80 entrypoint 301-redirects to 443, which breaks POSTs.
- DNS: A records in `platform/kubernetes/technitium/zones/wind.etherport.net.yaml`
  (synced to Technitium by the dns-watcher in ~5s).
- **Access control = UDM firewall, not a Traefik ipAllowList.** The shared Traefik
  LoadBalancer runs `externalTrafficPolicy: Cluster` → kube-proxy SNATs the client
  IP, so an ipAllowList 403s everything (same gotcha as the Protect webhook). The
  endpoints are unauthenticated internal sinks; the network boundary is the gate.

## Firewall — already permitted (no change)
The mini is **switch-routed/zoneless**, so its routed traffic enters the UDM via
the **Internal** transit zone, and `udm-firewall.yml` already has
**`Internal → Trusted (all) ALLOW`** (index 12070). The Traefik VIP is in
Trusted/201, so mini→VIP:443 is allowed. (Confirmed by the mini's existing
`kubectl` access to the 201 control plane.) No firewall edit was required.

## Pushgateway persistence
Pushgateway keeps pushed series **in memory** — a pod restart would drop
`*_last_success_timestamp_seconds` and false-fire the staleness alerts. The
HelmRelease (`clusters/wind/helm-releases/pushgateway.yaml`) now mounts a 2Gi
`ceph-rbd` PVC at `/data` and runs `--persistence.file=/data/pushgateway.store
--persistence.interval=5m` (+ `serviceMonitor.honorLabels: true` so pushed
job/instance labels survive scraping).

## Alerts (`09-photos-export-alerts.yaml`, → Alertmanager)
| Alert | Sev | Expr (summary) |
|---|---|---|
| `PhotosExportStale` | critical | `time() - max(cairn_backup_last_success_timestamp_seconds) > 93600` (>26h; nightly 22:00 PT) — catches failed **and** skipped runs |
| `PhotosExportNoMetrics` | warning | `absent(cairn_backup_last_success_timestamp_seconds)` for 48h — mini stopped pushing / Pushgateway data lost |
| `PhotosExportFailed` | warning | `max(cairn_backup_last_rc) > 0` for 30m |
| `PhotosExportNotParsed` | warning | `max(cairn_photos_summary_parsed) == 0` for 1h — a run finished but its summary/report wasn't parsed |
| `PhotosExportCoverageRegressed` | warning | `max(cairn_photos_missing_resolvable) > 0` for 1h — backup coverage of *fetchable* files dropped below 100% |
| `PhotosExportOrphansGrowing` | warning | `delta(cairn_photos_orphans[26h]) > 50` for 1h — untracked-dup count *rising* (not the absolute baseline) |

The success-ts is pushed under its own group (`job="photos_export_lastsuccess"`)
so a failed run can't wipe the last-success marker.

**`missing` is split** (2026-06-22): `cairn_photos_missing_resolvable` =
genuinely-missing originals a re-download (`DOWNLOAD_MISSING=1`) could fix (the
*actionable* number; 0 = 100% of available files backed up) and
`cairn_photos_missing_unavailable` = structurally un-fetchable items (edited
Live-Photo motion clips / `*_edited*.mov` Apple won't serve; ~9, expected,
**deliberately un-alerted**). The combined `cairn_photos_missing` is still
emitted. `PhotosExportCoverageRegressed` fires only on the *resolvable* count.

**`cairn_photos_orphans`** (added 2026-06-22): files present in the export dir but
**not** in osxphotos' ledger (untracked duplicates). Has a large legitimate
baseline (≈1,070) that *drops* after a NAS-local orphan delete, so the alert keys
on **growth** (a >50 rise over 26h), never the absolute value. Growth = new dups
being produced (a run without `--exportdb`, a race, etc.).

## Dashboard
"Mac mini — Photos backup" (`dashboards/photos-export.yaml`, uid `photos-export`):
**Coverage — available files** (`100·(1 − missing_resolvable/photos_total)`),
last-success age, last rc, exported, **Missing (resolvable)**, **Unavailable
(edited Live-Photo clips)**, **Orphan dup files** (sparkline); an exported /
resolvable / unavailable timeseries, run duration, and a Loki panel for
`{host="mini"}`.

## Verify
Cluster side (done):
```bash
kubectl get ingressroute -n monitoring pushgateway loki
dig +short @10.10.201.6 pushgateway.wind.etherport.net   # -> 10.10.201.70
# end-to-end through the VIP (valid TLS):
curl -sS -o /dev/null -w '%{http_code}\n' --resolve pushgateway.wind.etherport.net:443:10.10.201.70 https://pushgateway.wind.etherport.net/metrics  # 200
curl -sS -o /dev/null -w '%{http_code}\n' --resolve loki.wind.etherport.net:443:10.10.201.70 https://loki.wind.etherport.net/ready             # 200
```
Mini side (owner): `launchctl kickstart -k gui/$(id -u)/net.wind.photos-export`
(or wait for 22:00) → confirm `cairn_backup_*` / `cairn_photos_*` series appear in
Prometheus with `job="photos",instance="mini"` and `PhotosExportStale` clears; confirm
`{host="mini"}` logs in Grafana Explore.

## Optional follow-up
Loki ruler alert as a log-pattern complement, e.g.
`count_over_time({host="mini",job="photos-export"} |= "✗ export exited" [1h]) > 0`
(precedent: `monitoring/05-loki-rules-ipmi.yaml`). The metric alerts above already
cover failure/staleness, so this is additive.
