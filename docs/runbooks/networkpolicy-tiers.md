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

## How to detect a policy-caused break

Enforced drops are **not yet alerted** (the audit→Loki pipeline only catches `AUDIT`
verdicts; an H3 follow-up will add `verdict=DROPPED` → Loki → alert). Until then:

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
