# Runbook: GPU dcgm-exporter wedge (empty GPU dashboard / `TargetDown`)

**First seen:** 2026-06-19 (exporter flaky since ~06-10). **Node:** `k8s-gpu1` (Proxmox **VM 120**), the only GPU node.

## Symptom
- Grafana **GPU dashboard shows no data**.
- Prometheus alert **`TargetDown`** for `serviceMonitor/gpu-operator-system/nvidia-dcgm-exporter`.
- The dcgm `/metrics` endpoint **times out** (`context deadline exceeded`); exporter logs show
  `Failed to write response: i/o timeout`.
- On gpu1, **`nvidia-smi` itself hangs** (D-state) → the GPU **driver/DCGM is wedged at the kernel level**.

## Why the usual fixes don't work
`nvidia-dcgm-exporter` reads the GPU via DCGM; when the driver is wedged, the exporter hangs in
**uninterruptible (D) state**. So:
- a pod **restart leaves the old container stuck `Terminating`** and the new one stuck `Pending`
  (can't create while the wedged container holds the GPU),
- `crictl rm` / a fresh exporter just **re-hangs** on the same wedged driver.

**A reboot of gpu1 is the only reliable fix.** This is GPU **monitoring**, not compute — ollama/Plex
(CUDA) keep working until the reboot; the reboot just cycles them briefly.

## Fix (≈3–5 min; ollama + Plex restart)
```bash
kubectl cordon k8s-gpu1
# Reboot the VM via Proxmox (guest agent is unresponsive when wedged, so graceful-then-force):
ssh -i ~/.ssh/id_ed25519_homelab root@10.10.200.41 \
  "qm shutdown 120 --timeout 60 --forceStop 1 && qm start 120"
# Wait for the node to rejoin + the GPU stack to reinit:
kubectl get node k8s-gpu1 -w                                  # until Ready
kubectl -n gpu-operator-system get pods -w                    # operator-validator -> 1/1, dcgm-exporter -> 1/1
kubectl uncordon k8s-gpu1
```
The graceful-then-force order lets the Ceph RBD volumes unmount cleanly (a hard `qm stop` can leave a
**stale EIO mount** on ollama/Plex PVCs — if a pod CrashLoops afterward with `input/output error`,
`kubectl delete pod <name>` forces a fresh remount; see session-log 2026-06-19 / postgres-cluster-6).

## Verify
```bash
# dcgm endpoint serves metrics again:
NEWIP=$(kubectl -n gpu-operator-system get pods -l app=nvidia-dcgm-exporter -o jsonpath='{.items[0].status.podIP}')
kubectl -n monitoring exec prometheus-monitoring-kube-prometheus-prometheus-0 -c prometheus -- \
  sh -c "wget -qO- -T8 http://$NEWIP:9400/metrics | grep -c '^DCGM_'"        # > 0
# metric queryable (dashboard will populate):
kubectl -n monitoring exec prometheus-monitoring-kube-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL'  # has a result
kubectl uncordon k8s-gpu1   # ollama/plex reschedule back to gpu1 automatically
```

## Durability notes
- **Visibility:** the `TargetDown` PrometheusRule fires on dcgm scrape failure → routes to the AI advisor
  (email). That's the early-warning; act on it rather than discovering it via an empty dashboard.
- **No IaC self-heal:** the gpu-operator `ClusterPolicy.dcgmExporter` does **not** expose a `livenessProbe`,
  so we can't make the exporter auto-restart-on-hang via IaC (and a probe can't kill a D-state container
  anyway). The reboot above is the remediation; this runbook is the fast path.
- gpu-operator is Flux/helm-managed: `clusters/wind/helm-releases/gpu-operator.yaml` +
  `platform/kubernetes/gpu-operator/values.yaml`.
- If wedges become frequent, investigate the NVIDIA driver/DCGM version (ClusterPolicy `driver` /
  `dcgmExporter.version`) — a recurring kernel wedge usually means a driver bug.
