# TechnitiumDNSDown

Two rules share this name:
- `dns-service.rules / TechnitiumDNSDown` — external Technitium hosts
  (dns-aws, dns-fallback) unreachable for 1 minute.
- `dns-services / TechnitiumDNSDown` — in-cluster `technitium` StatefulSet
  has <2 ready replicas for 3 minutes.

Severity: critical. No auto-action — DNS is a foundational dependency
of the advisor itself (Loki, GitHub API, SMTP all need DNS).

## Symptom

DNS resolution from cluster workloads becomes unreliable or fails
entirely. Cascading symptoms: ImagePullBackOff (registry DNS),
TLS handshake failures (CDN DNS), Loki / Alertmanager visibility
gaps. The external variant pages on the on-prem and AWS DNS
appliances; the in-cluster variant pages on the StatefulSet replicas.

## Verified root cause(s)

- (External) Host actually down — AWS instance stop, on-prem power /
  network event, or a runaway `prune_host_logdir` that took the
  syslog path along with it (avoided via wrapper-script allowlist).
- (External) `ExternalHostLowDisk` cascaded — DNS service refused to
  start due to no space. Pairs with the disk alert.
- (In-cluster) Node tainted / drained while the StatefulSet pods
  were on it; topology-spread didn't relocate them.
- (In-cluster) PVC / longhorn issue preventing pod startup.

## Fix history

- 2026-05-25 (commit 72de9bc): Wired `additional-scrape-configs` Secret
  into Prometheus so the external Technitium hosts are scraped at all —
  prior to this, the external rule could fire spuriously on missing
  metrics. Not a fix of a real outage, but a fix of an observability
  gap.

## Verification steps

1. (External) Is the host actually reachable?
   `ping <host>`, `ssh <host>`, or check ipmi/console (on-prem) /
   EC2 instance status (AWS).
2. (External) Technitium service status:
   `ssh <host> systemctl status technitium-dns`
3. (External) Disk health (cascade check):
   `ssh <host> df -h /var/log /var/lib`
4. (In-cluster) StatefulSet status:
   `kubectl -n dns get statefulset technitium -o wide`
   `kubectl -n dns get pods -l app=technitium`
5. (In-cluster) PVC status:
   `kubectl -n dns get pvc`
6. Resolution test from any pod:
   `kubectl run dns-test --rm -it --image=busybox -- nslookup google.com`

## Advisor action guidance

- (External) `restart_systemd_unit(host=<name>, unit=technitium-dns)`
  is the textbook action — but it's Tier 3 manual-approval (NOT
  auto-eligible) precisely because DNS restarts are blast-radius-bearing.
- (External) If sibling `ExternalHostLowDisk` is also firing, fix the
  disk first via `prune_host_logdir` or `journal_vacuum`.
- (In-cluster) `restart_pods(namespace=dns, selector=app=technitium)`
  is appropriate when pods are crashlooping but the SS itself is
  healthy. Avoid restarting all replicas at once — do one at a time.
- `noop` if the host is genuinely down (no network / power) — that's
  an operator-level recovery.
