# Runbook — NetworkPolicy tiers (H3) & catering for new services

Cilium enforces per-namespace NetworkPolicies (H3). **`policy-audit-mode` is OFF
(enforcing).** Manifests: [`platform/kubernetes/networkpolicies/`](../../platform/kubernetes/networkpolicies/)
(see its `README.md` for the model + the audit-toggle workflow). This runbook is the
**operational** companion: what to do when you add or change a service so you don't
silently break its connectivity.

## The model in one paragraph

A namespace is **allow-all until labelled** `netpol.wind/enforced: "true"`. Once
labelled, its pods become **default-deny** in any direction a policy gives them rules,
and they get only: the cluster-wide allows (`allow-dns`, `allow-cluster-essentials` =
DNS + kube-apiserver + host/remote-node probes, `allow-monitoring-scrape` = ingress
from the `monitoring` ns) **plus** that tier's own allowlist (`1x-tier-<ns>.yaml`).
Everything else is dropped. Unlabelled namespaces are unaffected (allow-all).

**Enforced tiers (2026-06):** `postgres`, `cue`, `dns`, `traefik` (in progress).
Never label `kube-system`, `flux-system`, `wireguard`, `metallb-system`.

## ⚠️ Adding a new service WILL need NetworkPolicy work if it touches an enforced tier

This is the operational tax of enforcement. Three cases — check each when adding or
changing a workload:

1. **New workload IN an enforced namespace** (e.g. a new pod in `cue`/`dns`, or a new
   container that makes outbound calls). It inherits default-deny. Any connectivity
   beyond DNS/apiserver/host/monitoring must be added to that namespace's
   `1x-tier-<ns>.yaml` (both directions). Symptom if missed: the new pod can't reach
   its deps / can't be reached.

2. **New workload (in ANY namespace) that must REACH an enforced namespace** — e.g. a
   new app that uses the shared `postgres`, or that calls `cue-api`. The *target* tier's
   **ingress** allowlist must add the new source namespace. Symptom if missed: the new
   app's connections to the enforced service are dropped (timeouts), even though the new
   app's own namespace is unrestricted.

3. **New backend that Traefik routes to.** Traefik's egress is deliberately permissive
   (`toEntities: cluster` = all in-cluster backends, so **internal** routes never need
   changes). BUT a backend on an **external** host (a new `*-external` service → a device
   IP) needs `traefik`'s egress `world` ports extended if it's not 80/443/8006. Symptom:
   the route 502s.

> Rule of thumb: **if the new thing crosses an enforced namespace boundary, update that
> tier's allowlist in the same change.** Unlabelled-to-unlabelled traffic needs nothing.

## Adding monitoring for a new service (`monitoring` is enforced — open the channel)

`monitoring` is an enforced tier (`14-tier-monitoring.yaml`). Most monitoring paths are
already covered by its **permissive** design, but check by mechanism:

- **Prometheus scrape (pull, ServiceMonitor/PodMonitor)** of an **in-cluster** service:
  ✅ no action. monitoring's egress is `toEntities: cluster` (any port), and the target's
  ingress is covered either by `allow-monitoring-scrape` (if the target ns is enforced —
  it allows all ports from `monitoring`) or by allow-all (if unenforced).
- **Prometheus scrape of an EXTERNAL target** (a host/VM/device via
  `01-external-scrape-config.yaml`): ⚠️ **action** — monitoring egresses to `world` only on
  the enumerated ports (currently `:9100` node-exporter, `:9290` pve-IPMI, plus
  80/443/587/465/25). A new external target on a **different** port needs that port added to
  `14-tier-monitoring.yaml` egress `world`. Symptom: target shows `DOWN` in Prometheus.
- **Push to pushgateway** (`:9091`): in-cluster pusher ✅ (ingress `cluster`); external
  pusher (a new host) ✅ (ingress `world:9091`). Only a non-standard port needs work.
- **Logs to Loki** (`:3100`) / **syslog to Alloy** (`:514`): in-cluster ✅ (`cluster`);
  external shipper/device ✅ (`world:3100`/`:514`). New receiver port → add to ingress.
- **New external NOTIFIER egress** (Alertmanager to a new SMTP/webhook host, a new API for
  the advisor): add its port to `14-tier-monitoring.yaml` egress `world` (have: 443/587/465/25).

> TL;DR for monitoring: **in-cluster scrape/push/logs just work; a new EXTERNAL scrape
> target or notifier on a non-standard port needs a `world` port added to the monitoring
> tier.** Always verify with `hubble observe --namespace monitoring --verdict DROPPED` and
> check the Prometheus `Targets` page after adding a scrape.

## How are we notified / where are drops stored?

**Stored in Loki.** Cilium exports both `AUDIT` and `DROPPED` flows
(`cilium-config` `hubble-export-allowlist`={verdict:[AUDIT,DROPPED]}) → per-node file →
Alloy → Loki **`{job="hubble-audit"}`** (query/browse in Grafana Explore; retention =
Loki's). **Alerted via Alertmanager** by the loki-ruler rule **`CiliumNetpolDropFlow`**
(`platform/kubernetes/monitoring/06-loki-rules-cilium-audit.yaml`): fires (warning, →
the normal Alertmanager email/notification path) when a **DROPPED** flow involving an
enforced namespace from an **in-cluster** source is sustained 15m — i.e. "a channel may
need opening." The alert names the `src_ns → dst_ns:port`; act on it per "Adding or
changing a service" above (add to the per-tier CNP allowlist, or leave blocked if it's
unwanted). During a tier's observation window the sibling `CiliumNetpolAuditFlow` does
the same for `AUDIT` would-be-drops.

> Caveat: an **external** dropped client (`src=world`, e.g. a new off-cluster pusher on
> an unallowed port) does NOT trigger `CiliumNetpolDropFlow` (world drops are mostly
> scans = noise). Find those manually with the `hubble observe` recipe below.

## How to detect a policy-caused break (manual / immediate)

For an immediate look (or external-source drops the alert excludes):

```bash
# On the node running the affected pod (find with: kubectl get pod -n <ns> -o wide):
CIL=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=<node> -o name | head -1)
kubectl exec -n kube-system ${CIL#pod/} -c cilium-agent -- hubble observe --namespace <ns> --verdict DROPPED --last 200
```

A `POLICY_DENIED` drop tells you the exact src→dst:port to allowlist. (Benign exception:
DNS shows ICMP type-3 port-unreachable noise — already allowlisted.)

## Fix workflow

1. Identify the dropped flow (above): source ns/entity, destination, port, direction.
2. Edit the relevant `platform/kubernetes/networkpolicies/1x-tier-<ns>.yaml` (the
   *target* tier for an ingress gap; the *source* tier for an egress gap). Mirror the
   patterns already in `10-tier-postgres.yaml` / `11-tier-cue.yaml` / `12-tier-dns.yaml`.
3. `kubectl apply --dry-run=server -f <file>` to validate against the live Cilium CRDs.
4. Commit + push; Flux reconciles. Re-check `hubble observe --verdict DROPPED` = clean.

## Adding a whole new TIER (enforce a new namespace)

See `platform/kubernetes/networkpolicies/README.md` → "Adding the next tier". Short
version: audit is a single GLOBAL switch, so flip it back ON (`kubectl -n kube-system
patch cm cilium-config --type merge -p '{"data":{"policy-audit-mode":"true"}}'` +
`kubectl -n kube-system rollout restart ds/cilium`; set `cilium_policy_audit_mode: true`
in the kubespray inventory), label the namespace, observe `{job="hubble-audit"}` in Loki
for ≥days, build its `1x-tier-<ns>.yaml` until it AUDITs nothing, then flip OFF. The
small/well-characterised tiers (postgres/cue/dns) were done directly from Hubble
forwarded-flow data without the toggle; high-fanout tiers (traefik, monitoring) use the
toggle.

## Emergency rollback

- One namespace misbehaving: remove its `netpol.wind/enforced` label (git) → allow-all
  in ~1 reconcile. (Or `kubectl label ns <ns> netpol.wind/enforced-` for an immediate
  out-of-band stopgap; Flux will reconcile the git state after.)
- Cluster-wide "stop enforcing NOW": `kubectl -n kube-system patch cm cilium-config
  --type merge -p '{"data":{"policy-audit-mode":"true"}}'` + `kubectl -n kube-system
  rollout restart ds/cilium`. Works without cluster DNS (kubectl talks to the apiserver
  by IP). Everything reverts to audit-only (logs, enforces nothing).

## Related
- [`platform/kubernetes/networkpolicies/README.md`](../../platform/kubernetes/networkpolicies/README.md) — policy model + manifests
- [`cilium-cni-dir-owner.md`](cilium-cni-dir-owner.md) — never run raw kubespray cilium (cni-dir owner landmine)
- `docs/planning/outstanding-work.md` H3 — rollout status
