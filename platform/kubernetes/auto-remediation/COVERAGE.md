# Auto-Remediation Coverage

What the controller knows how to do, what Prometheus actually fires,
and the gap between them.

Last reviewed: 2026-05-22.

## Wiring — the elephant in the room

**Alertmanager is NOT routing alerts to the remediation webhook.**

The remediation controller listens on
`http://remediation-webhook.auto-remediation.svc.cluster.local:8080/webhook`
but no Alertmanager receiver is configured to call it. All rules
below are dormant until a webhook receiver is added.

To wire: add a receiver + route in
`platform/kubernetes/monitoring/03-alertmanager-config.yaml`:

```yaml
receivers:
  - name: auto-remediation
    webhookConfigs:
      - url: http://remediation-webhook.auto-remediation.svc.cluster.local:8080/webhook
        sendResolved: false
route:
  routes:
    - matchers:
        - { name: severity, value: critical }
      receiver: auto-remediation
      continue: true   # ALSO send to email-alerts
```

Use `continue: true` so the same alert reaches both the webhook AND
your inbox. The remediation controller's 15-min cooldown prevents
restart loops.

## Defined remediation rules (configmap.yaml)

22 rules across 7 functional areas. All `action: restart_pods` unless
noted. All rules apply selector-based pod deletion (replicas come back
automatically).

| Alert name | Namespace | Action target | Notes |
|---|---|---|---|
| `NodeLocalDNSHighErrorRate` | kube-system | `k8s-app=node-local-dns` | |
| `NodeLocalDNSTimeout` | kube-system | `k8s-app=node-local-dns` | |
| `CoreDNSDown` | kube-system | `k8s-app=kube-dns` | |
| `TechnitiumDNSDown` | dns | `app=technitium` | |
| `HomeAssistantDown` | home-automation | `app=home-assistant` | |
| `HomeAssistantPodCrashLooping` | home-automation | deployment `home-assistant` | `scale_deployment` (down/up cycle) |
| `GrafanaDown` | monitoring | `app.kubernetes.io/name=grafana` | |
| `PrometheusDown` | monitoring | `app.kubernetes.io/name=prometheus` | |
| `AlertmanagerDown` | monitoring | `app.kubernetes.io/name=alertmanager` | |
| `TraefikDown` | traefik | `app.kubernetes.io/name=traefik` | |
| `CertManagerDown` | cert-manager | `app.kubernetes.io/name=cert-manager` | |
| `CertManagerWebhookDown` | cert-manager | `app.kubernetes.io/name=webhook` | |
| `FluxHelmControllerDown` | flux-system | `app=helm-controller` | |
| `FluxKustomizeControllerDown` | flux-system | `app=kustomize-controller` | |
| `FluxSourceControllerDown` | flux-system | `app=source-controller` | |
| `KopiaDown` | backups | `app=kopia` | |
| `VeleroDown` | velero | `app.kubernetes.io/name=velero` | |
| `MetalLBControllerDown` | metallb-system | `app=metallb,component=controller` | |
| `PlexDown` | plex | `app=plex` | |
| `PodCrashLooping` | (generic, label-driven) | restart matching | demoted to severity=info 2026-05-22 |
| `PodOOMKilled` | (generic) | restart matching | demoted to severity=info 2026-05-22 |
| `PodNotReady` | (generic) | restart matching | demoted to severity=info 2026-05-22 |

## Coverage by service category

### ✅ Covered
- DNS: NodeLocalDNS, CoreDNS, Technitium
- Monitoring: Grafana, Prometheus, Alertmanager
- Ingress + TLS: Traefik, cert-manager (controller + webhook)
- GitOps: Flux (helm/kustomize/source controllers)
- Backup: Kopia, Velero
- Network LB: MetalLB controller
- Apps: Home Assistant (deep — restart + scale-down/up), Plex

### ❌ NOT covered (worth adding)
- **CNPG** (`cnpg-system/cnpg-cloudnative-pg`) — Postgres operator. Failures here block all stateful apps.
- **ceph-csi RBD provisioner** (`default/csi-rbdplugin-provisioner`) — if this is down, no new PVCs.
- **WireGuard K8s pod** (`wireguard/wireguard`) — single replica, VRRP backup is vpn-local. The 2026-05-22 incident showed VRRP failover IS automatic but slow without preStop fixes.
- **Multus DS** (`kube-system/kube-multus-ds-amd64`) — secondary NIC attachments.
- **MetalLB speakers** (currently only `MetalLBControllerDown` covered; speaker DS not). Speakers were the cause of the technitium aggregator advertisement bug (#33).

### ⚠ Partial coverage / probably-OK gaps
- **Cilium / Cilium operator** — restarting these mid-flight is risky; cluster networking depends on it. Better to alert + manual.
- **etcd / kube-apiserver / kube-controller-manager** — these are managed by kubespray static pods; a restart_pods action would require a different mechanism. Leave to kured + node lifecycle.
- **Kubelet / containerd** — node-level, outside K8s control plane.

## Cooldown + safety

- Per-rule cooldown: 15 min (hardcoded `COOLDOWN_MINUTES` in `controller.py`).
- Webhook is namespace-scoped via RBAC (`rbac.yaml`) — can restart pods in any namespace but cannot delete cluster-scoped resources.
- All actions log an email via the same SES SMTP secret as alertmanager (visible via `kubectl logs -n auto-remediation -l app=remediation-controller`).
- No exponential backoff. Repeated alerts within cooldown are silently dropped, not queued.

## To do — concrete follow-ups

1. **Wire the webhook receiver** (above) — until then, all rules are dormant.
2. Add rules for CNPG operator, ceph-csi-rbdplugin-provisioner, WireGuard, MetalLB speakers.
3. Consider exponential backoff if cooldown alone isn't enough for flappy services.
4. Wire a Prometheus `up` metric for the remediation controller itself — meta-monitoring.
