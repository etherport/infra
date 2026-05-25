"""
Single source of truth for the homelab service-status inventory.

Both `service-status-report.py` (the daily email CronJob) and
`gen-dashboard.py` (the Grafana dashboard generator) import this list.
Edit here once and re-run `gen-dashboard.py` to refresh the dashboard;
the email script picks up changes on its next CronJob fire because
this file is mounted alongside the script via the
`service-status-report-script` ConfigMap.

Each tuple: (category, display_name, kind, namespace, target)
  - kind ∈ {deployment, statefulset, daemonset, external}
  - For external: `namespace` is the Prometheus scrape job name and
    `target` is the instance name prefix (e.g. "dns-fallback").
  - For others: standard K8s namespace + workload name.

When a target doesn't exist in Prometheus, the email/dashboard render
"unknown" rather than failing. So a stale entry is loud-but-safe; a
missing entry is silent. Prefer the loud failure mode — keep this list
slightly ahead of what's deployed and remove only after a deletion is
confirmed (Flux-pruned).

Drift-detection: see `scripts/check-service-status-inventory.sh` for
the CI guard that compares this list against the live cluster.
"""

SERVICES = [
    # Core platform
    ("Core platform", "Grafana",                "deployment", "monitoring",     "monitoring-grafana"),
    ("Core platform", "Prometheus",             "statefulset","monitoring",     "prometheus-monitoring-kube-prometheus-prometheus"),
    ("Core platform", "Alertmanager",           "statefulset","monitoring",     "alertmanager-monitoring-kube-prometheus-alertmanager"),
    ("Core platform", "Traefik",                "deployment", "traefik",        "traefik"),
    ("Core platform", "cert-manager",           "deployment", "cert-manager",   "cert-manager"),
    ("Core platform", "cert-manager webhook",   "deployment", "cert-manager",   "cert-manager-webhook"),
    ("Core platform", "cert-manager cainjector","deployment", "cert-manager",   "cert-manager-cainjector"),

    # GitOps
    ("GitOps", "Flux helm-controller",         "deployment", "flux-system",    "helm-controller"),
    ("GitOps", "Flux kustomize-controller",    "deployment", "flux-system",    "kustomize-controller"),
    ("GitOps", "Flux source-controller",       "deployment", "flux-system",    "source-controller"),
    ("GitOps", "Flux notification-controller", "deployment", "flux-system",    "notification-controller"),

    # Networking + VPN
    ("Networking", "MetalLB controller",     "deployment", "metallb-system", "controller"),
    ("Networking", "MetalLB speakers",       "daemonset",  "metallb-system", "speaker"),
    ("Networking", "Multus CNI",             "daemonset",  "kube-system",    "kube-multus-ds-amd64"),
    ("Networking", "WireGuard",              "deployment", "wireguard",      "wireguard"),
    ("Networking", "Cloudflare Tunnel",      "deployment", "cloudflared",    "cloudflared"),
    ("Networking", "CloudWatch→Loki forwarder", "cronjob", "cloudwatch-to-loki", "cloudwatch-to-loki"),

    # Storage / data
    ("Storage / data", "CNPG operator",         "deployment", "cnpg-system", "cnpg-cloudnative-pg"),
    ("Storage / data", "Ceph CSI provisioner",  "deployment", "default",     "csi-rbdplugin-provisioner"),

    # DNS
    ("DNS", "Technitium DNS", "statefulset", "dns", "technitium"),

    # Backup
    ("Backup", "Velero", "deployment", "velero",  "velero"),
    ("Backup", "Kopia",  "deployment", "backups", "kopia"),

    # Apps
    ("Apps", "Home Assistant", "deployment", "home-automation", "home-assistant"),
    ("Apps", "Plex",           "deployment", "plex",            "plex"),
    ("Apps", "Ollama",         "deployment", "ollama",          "ollama"),

    # External edge (probed via external-nodes scrape job)
    ("External edge", "dns-fallback", "external", "external-nodes", "dns-fallback"),
    ("External edge", "dns-aws",      "external", "external-nodes", "dns-aws"),
    ("External edge", "vpn-local",    "external", "external-nodes", "vpn-local"),
    ("External edge", "vpn-aws",      "external", "external-nodes", "vpn-aws"),
]
