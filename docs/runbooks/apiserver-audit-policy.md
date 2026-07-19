# Runbook — apiserver audit policy (tightened)

**What / why.** The kube-apiserver audit log (M131, shipped to Loki `job=apiserver-audit`
by Alloy) was ~14 GB/day — ~70% of all Loki ingest — and filled `storage-loki-0` to 99%
(2026-07-19 `KubePersistentVolumeFillingUp` flood). Root cause: kubespray's stock GCE
audit policy logs **all reads at `Request`** and **all mutations at `RequestResponse`**,
with a catch-all `level: Metadata`. Byte-share: nodes-status heartbeats 36%, SAR/authz
14%, kyverno reports 13%, leases 6% — almost all noise.

**Fix.** A tightened policy that drops high-volume SYSTEM read/heartbeat/review/report/
probe traffic while keeping the security signal: all mutations, secret/configmap/RBAC
access, and **all human + anonymous requests** (the latter preserves the
`ApiserverAnonymousSuccess` / `ApiserverForbiddenBurst` Loki-ruler alerts in
`platform/kubernetes/monitoring/06-loki-rules-apiserver-audit.yaml`). ~80% volume cut.

## Source of truth

`infra/kubespray/inventory/group_vars/k8s_cluster/k8s-cluster.yml` →
`audit_policy_custom_rules` (the kubespray template inserts it under `rules:`). A
kubespray run renders it to `/etc/kubernetes/audit-policy/apiserver-audit-policy.yaml`
on each control-plane node (hostPath-mounted into the apiserver static pod at
`--audit-policy-file`).

## Applying (the apiserver re-reads the policy only at startup)

Two paths:

1. **kubespray run** (IaC-native, heavier — mind the cni-owner landmine; use
   `infra/kubespray/kubespray.sh`). Renders + restarts the apiservers.
2. **Targeted live apply** (faster). The apiserver reads the policy file only at
   startup, so the file must be replaced **and** each apiserver restarted. **There is no
   HA API VIP** (`controlPlaneEndpoint` = cp1 `10.10.201.50`; workers load-balance all
   3 CPs via local `nginx-proxy`), so **restart cp1 LAST** and one CP at a time,
   verifying health between:

   ```bash
   # per CP (10.10.201.52 cp3, .51 cp2, .50 cp1 — LAST):
   ssh ubuntu@<ip> 'sudo cp /etc/kubernetes/audit-policy/apiserver-audit-policy.yaml{,.bak}
     sudo tee /etc/kubernetes/audit-policy/apiserver-audit-policy.yaml < new-policy.yaml
     sudo crictl rm -f $(sudo crictl ps -q --name kube-apiserver)'   # kubelet recreates it
   # verify before moving to the next CP:
   kubectl get --raw /healthz            # ok
   kubectl get nodes                     # Ready
   ```

   Rollback: restore the `.bak` and restart the apiserver the same way.

## Verify

- `kubectl get --raw /healthz` = `ok`, all nodes Ready, no apiserver CrashLoop.
- Loki: `job=apiserver-audit` volume drops ~80% (Grafana Explore / `index/volume`).
- Alerts still armed: force a `system:anonymous` 2xx or a 403 burst and confirm the
  ruler rules still see events (mutations + human/anon reads are still logged).
