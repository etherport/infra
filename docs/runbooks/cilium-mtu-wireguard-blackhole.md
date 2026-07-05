# Runbook — Cilium MTU black hole on the WireGuard-pod node

**TL;DR:** Cilium's MTU **auto-detect** (`MTU: 0`) can latch onto the K8s
WireGuard pod's `wg0`/`wg1` host interfaces (MTU **1420**) instead of `eth0`
(jumbo **9000**) — but only on **whichever node currently hosts the
`wireguard` pod**, and only after a **cilium-agent (re)start** there (e.g. a node
reboot during an upgrade). That node's `cilium_wg0` then comes up at **1340**
instead of 8920, creating a **small-works / large-fails black hole**: health
probes pass (Cilium reports all-healthy) but any large packet — a TLS handshake
to the apiserver ClusterIP, a metrics scrape response — silently drops.
**Fixed durably by pinning `MTU: 9000`** (eth0's value; Cilium derives
`cilium_wg0` = 8920 from it). Live 2026-07-05.

## Symptoms (all present together)

- `TargetDown` for a `:9400`/`:9100`/etc. scrape whose **pod is `1/1 Running`**
  and serving locally — the scrape URL times out (`context deadline exceeded`,
  NOT connection refused).
- Pods on the affected node crash-loop with `... connection timed out` to
  **`10.43.0.1:443`** (the apiserver ClusterIP) — e.g. node-feature-discovery
  workers with 40+ restarts.
- `cilium-dbg status` says **OK / all controllers healthy / N/N reachable** —
  the node-health probe uses small packets, so it passes. **This is the trap:
  Cilium reports healthy while the datapath black-holes real traffic.**

## Diagnose

```bash
# The tell: the WG-pod node's cilium_wg0 MTU is 1340 vs 8920 on healthy nodes.
for n in <wg-pod-node-ip> <a-healthy-node-ip>; do
  ssh ubuntu@$n 'ip link show cilium_wg0 | grep -oE "mtu [0-9]+"'
done
# Confirm eth0 IS jumbo on the bad node (so the base device is fine — auto-detect
# just picked the wrong interface):
ssh ubuntu@<bad-node> 'ip link show eth0 | grep -oE "mtu [0-9]+"'   # 9000
# Which node hosts the WG pod (explains WHICH node is affected):
kubectl -n wireguard get pods -l app=wireguard -o wide
# Cilium's own MTU jobs on the bad node show the wrong base:
kubectl -n kube-system exec <cilium-pod-on-bad-node> -c cilium-agent -- \
  cilium-dbg status --verbose | grep -iE 'job-mtu'   # "MTU updated (1420)" = wrong
```

## Fix (durable — pin the MTU)

Cilium is **Helm-managed** (release `cilium`/kube-system), so change it via
`helm`, NOT kubespray ([[cilium-cni-dir-owner]] landmine). Follow the
[[cilium-upgrade]] procedure — including the **`--reset-then-reuse-values`
fallback + `policyAuditMode=false` re-assert** (a plain `--reuse-values` hits a
template nil-pointer on current chart minors):

```bash
export PATH="$HOME/.local/bin:$PATH"          # helm v3.19 on the devbox
helm upgrade cilium cilium/cilium -n kube-system --reset-then-reuse-values \
  --set MTU=9000 --set policyAuditMode=false
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status  ds/cilium --timeout=5m
```

Then **persist so a kubespray run can't revert it**: set `cilium_mtu: "9000"`
in `infra/kubespray/inventory/group_vars/k8s_cluster/k8s-net-cilium.yml` (and the
`infra/ansible/inventory/wind/...` mirror), and refresh
`docs/reference/snapshots/cilium-helm-values.yaml`.

## Verify (the 4-point + the scrape)

```bash
ssh ubuntu@<bad-node> 'ip link show cilium_wg0 | grep mtu'          # ~8905/8920, not 1340
kubectl -n monitoring exec sts/prometheus-... -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up{job="nvidia-dcgm-exporter"}'   # up=1
# runbook 4-point: PolicyAuditMode Disabled, encrypt status Wireguard, BGP 8/8, 0 drops
```

## See also
- [[cilium-upgrade]] — the reset-then-reuse + re-assert procedure this uses.
- [[cilium-cni-dir-owner]] — why Cilium is Helm-managed, never kubespray.
