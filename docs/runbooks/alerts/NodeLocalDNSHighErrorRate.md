# NodeLocalDNSHighErrorRate

Fires when CoreDNS SERVFAIL rate on the node-local-dns pods exceeds
0.05/sec sustained 2 minutes. Severity: warning. Labeled
`ai_remediation: "auto"` — auto-eligible action: `restart_pods`.

## Symptom

PrometheusRule `dns / NodeLocalDNSHighErrorRate` firing on one or more
nodes. In practice manifests as flaky DNS resolution from pods on the
affected node — apps see intermittent `SERVFAIL` / DNS timeout errors.
Often correlates with sibling `NodeLocalDNSTimeout`.

## Verified root cause(s)

- node-local-dns pod has lost its forwarding peer (CoreDNS pod
  restarted, or upstream resolver path broken via SDN / firewall
  change) — restart usually re-resolves the upstream.
- UDP-vs-TCP forwarding mismatch with upstream Technitium (the
  `force_tcp` → `prefer_udp` Corefile change in
  `nodelocaldns-udp-fix.yaml`).
- Upstream Technitium DNS itself is degraded — check sibling
  `TechnitiumDNSDown` first.
- Conntrack saturation on a busy node — less common; surfaces via
  `nf_conntrack: table full` in dmesg.

## Fix history

- 2026-05-24 (commit b5f2ab7): Added `ai_remediation: "auto"` label
  enabling Phase 3 autonomous `restart_pods` on this alert. Confidence
  threshold elevated to 0.85 per the week-1 rollout doc.

## Verification steps

1. Per-node SERVFAIL rate in Prometheus:
   `rate(coredns_dns_responses_total{job="node-local-dns",rcode="SERVFAIL"}[5m])`
2. Check the failing node-local-dns pod:
   `kubectl -n kube-system get pods -l k8s-app=node-local-dns -o wide`
   `kubectl -n kube-system logs <pod> --tail=100`
3. From a pod on the affected node, test resolution:
   `kubectl debug node/<node> -it --image=busybox -- nslookup google.com`
4. After restart, error rate should drop to ~0 within one scrape.

## Advisor action guidance

- Preferred (auto): `restart_pods(namespace=kube-system, selector=k8s-app=node-local-dns, node=<nodename>)`
  — restarts only the affected DaemonSet pod, no broad disruption.
- Avoid restarting all node-local-dns pods at once — that briefly
  blackholes DNS cluster-wide. The action defaults to single-node.
- If `TechnitiumDNSDown` is also firing, defer to that runbook —
  restarting node-local-dns won't help if the upstream is gone.
- `noop` is appropriate if logs show a conntrack-full or kernel-side
  issue that needs operator investigation.
