# Loki log aggregation

Centralized log store for the wind cluster. Loki single-binary + Grafana
Alloy DaemonSet. Replaces "logs only live in pod stdout".

## Topology

```
  pods (kubelet /var/log/pods)
      |
      v
  alloy DaemonSet  <----- syslog UDP/TCP 514 (10.10.201.73)
      |                       ^
      |                       |
      |              UDM-Pro / USW / USG
      v
  loki (singleBinary, ceph-rbd PVC 20Gi, 30d retention)
      |
      v
  grafana (datasource: Loki, auto-provisioned via ConfigMap)
```

Manifests:

- `clusters/wind/helm-releases/loki.yaml` — Loki HelmRelease
- `clusters/wind/helm-releases/alloy.yaml` — Alloy HelmRelease + syslog
  LoadBalancer Service (`10.10.201.73`)
- `platform/kubernetes/monitoring/loki-datasource.yaml` — Grafana
  datasource ConfigMap (sidecar-loaded)
- `clusters/wind/helm-releases/repositories.yaml` — `grafana` HelmRepo

## Querying

Grafana → Explore → Datasource: **Loki**.

LogQL cheat sheet:

```logql
# All logs from a pod
{namespace="monitoring", pod=~"prometheus-.*"}

# Errors across the whole cluster, last 1h
{cluster="wind"} |= "error" | json

# Syslog from the UDM, last 15m
{job="syslog"} |~ "10.10.200.1"

# CrashLoopBackOff context — last 200 lines of a container before death
{namespace="home-automation", container="home-assistant"} | logfmt
```

Useful prefixes:

- `|= "needle"` — line contains
- `!= "noise"` — line excludes
- `|~ "re"` / `!~ "re"` — regex
- `| json` / `| logfmt` — parse structured fields
- `| line_format "{{.level}} {{.msg}}"` — reformat

## Adding new log sources

### A new namespace / pod

Nothing to do. Alloy's `discovery.kubernetes "pods"` discovers every pod
on every node automatically. New pods show up in Loki within seconds.

### A new syslog device

1. On the device, point syslog at `10.10.201.73` UDP 514 (TCP 514 also
   works; use TCP if the device supports it — UDP drops on congestion).
2. Verify in Grafana:
   ```logql
   {job="syslog"} |~ "<device-hostname-or-ip>"
   ```
3. If nothing arrives within a minute, check the Alloy pod logs on the
   node MetalLB currently routes `.73` to:
   ```sh
   kubectl -n metallb-system get svc -A | grep 10.10.201.73
   kubectl -n monitoring logs ds/alloy --tail=200 | grep -i syslog
   ```
4. UDM/USG firewall: ensure egress from the device's mgmt VLAN to
   `10.10.201.0/24:514` isn't blocked. The MetalLB IP lives on the
   server VLAN (201), so most setups already allow this.

### A non-syslog external source (e.g. journald on a non-K8s VM)

Two options:

- **Best**: install Alloy or Promtail on the VM and point at the cluster
  Loki push endpoint. Loki has no auth, but it's ClusterIP-only — you'd
  have to expose it (LoadBalancer on a second IP, or a Traefik
  IngressRoute). Out of scope today.
- **Hack**: get the VM to emit syslog and forward it to `10.10.201.73`.

## Retention + storage

- **Retention**: 30 d, enforced by the compactor. Change
  `loki.limits_config.retention_period` in
  `clusters/wind/helm-releases/loki.yaml`.
- **PVC size**: 20Gi on `ceph-rbd`. To grow:
  1. Edit `singleBinary.persistence.size` in the HelmRelease.
  2. Flux applies it. Ceph RBD supports online expansion — the pod
     stays up.
  3. If the PVC StorageClass doesn't have `allowVolumeExpansion: true`
     (it should), check `kubectl get sc ceph-rbd -o yaml`.
- **When to flip to S3**: when log volume routinely exceeds ~10 GB/day
  or you want >90d retention. Loki's tsdb schema supports filesystem →
  s3 migration by adding a second `schemaConfig.configs` entry with a
  future `from:` date and `object_store: s3`. Old chunks stay on the
  PVC, new ones go to S3. We'd use the same Velero S3 user — needs a
  new bucket (`loki-chunks-wind` or similar) and an IAM policy update.
  Tracked separately.

## Health checks

```sh
# Loki is up
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki
curl -s http://loki.monitoring.svc.cluster.local:3100/ready  # from in-cluster

# Alloy DaemonSet healthy on every node
kubectl -n monitoring get ds alloy

# How many bytes Loki is ingesting per second (from Prometheus)
sum(rate(loki_distributor_bytes_received_total[5m]))

# PVC usage
kubectl -n monitoring get pvc
```

## Known gotchas

- **Syslog source IPs**: the syslog Service uses
  `externalTrafficPolicy: Local` so the device's real IP is preserved.
  This means MetalLB only advertises `.73` from nodes that currently
  have an Alloy pod (always true since Alloy is a DaemonSet) and traffic
  pins to one node — no cross-node hop. If you ever scale Alloy down,
  re-check.
- **`X-Scope-OrgID: fake`**: Loki runs single-tenant
  (`auth_enabled: false`) but some Loki endpoints still require a tenant
  header. The datasource ConfigMap sets `fake` (the documented default).
  Don't change this unless you also flip Loki to multitenant.
- **`reportingEnabled: false`**: opted out of Grafana Labs anonymous
  usage stats in `loki.analytics`. Leave it that way.
- **Open monitoring TODO**: no Alertmanager rule yet for ingest backlog
  / Loki down / syslog stream stalled. Add a `PrometheusRule` under
  `platform/kubernetes/monitoring/` when the workload feels load-bearing
  enough to alert on.
