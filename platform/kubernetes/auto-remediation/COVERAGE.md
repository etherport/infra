# Auto-Remediation Coverage

What the controller knows how to do, what Prometheus actually fires,
and the gap between them.

Last reviewed: 2026-05-25.

## Wiring

**Live.** As of M8 (`7838270`, 2026-05-24) Alertmanager routes
critical alerts through the webhook receiver in
`platform/kubernetes/monitoring/03-alertmanager-config.yaml`, with
`continue: true` so the same alert reaches both inbox + webhook.
Cooldown (15 min per alert+action) prevents restart loops.

The receiver:

```yaml
receivers:
  - name: auto-remediation
    webhookConfigs:
      - url: http://remediation-webhook.auto-remediation.svc.cluster.local:8080/webhook
        sendResolved: false
```

The advisor layer (Phases 1/2/3) sits behind the same webhook and
handles any alert that didn't match a static rule (see README.md
for the dispatch flow).

## Defined remediation rules (configmap.yaml)

21 rules across 7 functional areas. All `action: restart_pods` unless
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
| `VeleroDown` | velero | `app.kubernetes.io/name=velero` | |
| `MetalLBControllerDown` | metallb-system | `component=controller` | |
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
- Backup: Velero
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

### Advisor guardrails (Phase 3) — added 2026-05-26

Two independent layers prevent runaway loops on alerts that keep firing:

1. **Per-action daily frequency cap** (`AI_ACTION_DAILY_LIMITS` in `controller-configmap.yaml`). Capped per `(alertname, action_type)` over the last 24h via Loki audit search. Defaults: 10/day for cleanups (delete_completed_jobs etc.), 3-5/day for triggers + restarts, 1-2/day for high-stakes (rollback_deployment, cnpg_recreate_replica). When hit, the action returns failure with explanation and emits a `frequency_cap_hit` audit event.

2. **Self-tuning Phase 3 thresholds.** When `(alertname, action_type)` has recorded `verification_failed` events in the last 7 days, the auto-execute confidence requirement rises by 0.05 per failure (capped at +0.15 = 3 failures). Plottable in the AI advisor dashboard via the new `dynamic_threshold_applied` audit event.

### Advisor knowledge layer — added 2026-05-26

- **17 alert runbooks** at `docs/runbooks/alerts/*.md` — the advisor's `read_runbook` tool reads these BEFORE proposing actions, short-circuiting first-principles diagnosis for recurring alerts.
- **`search_git_log` + `read_runbook` tools** (deep-mode only) let the advisor pull institutional knowledge from the repo's commit history + curated runbooks during root-cause investigation.
- **Commit-trailer convention** (`docs/runbooks/auto-remediation/commit-trailers.md`) — adopt `Fixes-alert:` / `Root-cause:` trailers in fix commits so `search_git_log` queries become precise.

## To do — concrete follow-ups

1. Add rules for CNPG operator, ceph-csi-rbdplugin-provisioner, WireGuard, MetalLB speakers.
2. Consider exponential backoff if cooldown alone isn't enough for flappy services.
3. Wire a Prometheus `up` metric for the remediation controller itself — meta-monitoring.
