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
    ("Core platform", "Authentik server",       "deployment", "authentik",      "authentik-server"),
    ("Core platform", "Authentik worker",       "deployment", "authentik",      "authentik-worker"),
    # NB Authentik dropped its bundled Redis at 2025.10 (H44 upgrade) — the
    # deployment no longer exists, so this row rendered a permanent "unknown".
    # Removed 2026-07-05.

    # GitOps
    ("GitOps", "Flux helm-controller",         "deployment", "flux-system",    "helm-controller"),
    ("GitOps", "Flux kustomize-controller",    "deployment", "flux-system",    "kustomize-controller"),
    ("GitOps", "Flux source-controller",       "deployment", "flux-system",    "source-controller"),
    ("GitOps", "Flux notification-controller", "deployment", "flux-system",    "notification-controller"),

    # Networking + VPN
    # NB MetalLB workloads are `metallb-controller`/`metallb-speaker` (FRR-mode Helm
    # chart, L24) — NOT the kubespray `controller`/`speaker` (those names were retired).
    ("Networking", "MetalLB controller",     "deployment", "metallb-system", "metallb-controller"),
    ("Networking", "MetalLB speakers",       "daemonset",  "metallb-system", "metallb-speaker"),
    ("Networking", "Multus CNI",             "daemonset",  "kube-system",    "kube-multus-ds-amd64"),
    ("Networking", "WireGuard",              "deployment", "wireguard",      "wireguard"),
    ("Networking", "Cloudflare Tunnel",      "deployment", "cloudflared",    "cloudflared"),
    ("Networking", "CloudWatch→Loki forwarder", "cronjob", "cloudwatch-to-loki", "cloudwatch-to-loki"),

    # Security (admission + runtime detection — added 2026-06-28)
    ("Security", "Kyverno admission",  "deployment", "kyverno",  "kyverno-admission-controller"),
    ("Security", "Tetragon",           "daemonset",  "tetragon", "tetragon"),

    # Storage / data
    ("Storage / data", "CNPG operator",         "deployment", "cnpg-system", "cnpg-cloudnative-pg"),
    ("Storage / data", "Ceph CSI provisioner",  "deployment", "ceph-csi",    "csi-rbdplugin-provisioner"),

    # DNS
    ("DNS", "Technitium DNS", "statefulset", "dns", "technitium"),

    # Backup
    ("Backup", "Velero", "deployment", "velero",  "velero"),
    ("Backup", "Google Drive sync", "cronjob", "rclone", "gdrive-sync"),
    ("Backup", "OneDrive sync",     "cronjob", "rclone", "onedrive-sync"),

    # Config drift — each CI detector writes its last result to the `drift-status` ConfigMap
    # (monitoring ns) via .github/actions/report-drift-status; this pod mounts it at /drift.
    # `target` = the detector name (the ConfigMap data key). up=clean, down=DRIFT,
    # degraded=stale (no write in >26h), unknown=never reported. The full drift detail +
    # remediation is in that detector's GitHub issue (label e.g. tf-drift); this is the rollup.
    ("Config drift", "Terraform (24 stacks)",   "drift_status", "", "tf-drift"),
    ("Config drift", "Cloud tags (AWS Config)",  "drift_status", "", "cloud-tag-drift"),
    ("Config drift", "UDM firewall/zones",       "drift_status", "", "ansible-udm-firewall"),
    ("Config drift", "L3-switch ACLs",           "drift_status", "", "ansible-usw-acls"),
    ("Config drift", "Network topology",         "drift_status", "", "topology"),
    ("Config drift", "Cluster config",           "drift_status", "", "cluster-config"),
    ("Config drift", "step-ca PKI",              "drift_status", "", "step-ca-pki"),
    # (service-status-inventory-drift is WEEKLY — omitted here; a daily email would always
    #  show it "stale". It keeps its own GitHub issue.)

    # Apps
    ("Apps", "Home Assistant", "deployment", "home-automation", "home-assistant"),
    ("Apps", "Plex",           "deployment", "plex",            "plex"),
    ("Apps", "Ollama",         "deployment", "ollama",          "ollama"),
    ("Apps", "Cue API",        "deployment", "cue",             "cue-api"),

    # External edge — node_exporter on the standalone PVE VMs + AWS VMs, via the
    # `external-nodes` scrape job (01-external-scrape-config.yaml). Fleet is 6 local
    # PVE VMs (1001-1006) + 2 AWS; the M77 firewalls allow :9100 from the K8s VLAN.
    ("External edge", "dns-fallback", "external", "external-nodes", "dns-fallback"),
    ("External edge", "vpn-fallback", "external", "external-nodes", "vpn-fallback"),
    ("External edge", "gh-runner",    "external", "external-nodes", "gh-runner"),
    ("External edge", "devbox",       "external", "external-nodes", "devbox"),
    ("External edge", "vpn-aws",      "external", "external-nodes", "vpn-aws"),
    # ⏳ asterisk-sbc (1004 .40) + step-ca (1006 .46) NOT yet monitored: node_exporter
    #    isn't running on them (base.yml not applied — :9100 returns no listener, while
    #    gh-runner/.30 + vpn-local/.15 answer fine, so it's not the M77 firewall). Run
    #    base.yml on both, add them to 01-external-scrape-config.yaml, then list here.

    # Mac mini — cairn iCloud-backup agent (M103/M105). Pushgateway metrics:
    # mini_health_up (host), cairn_healthy (agent), cairn_backup_last_rc{job=<cat>}
    # per backup category (0 = last run ok). See gen-dashboard "Mac mini — iCloud
    # backups" + 10-icloud-backups-alerts.yaml.
    ("Mac mini (cairn)", "Mac mini host",      "mini_metric",  "mini_health", "mini_health_up"),
    ("Mac mini (cairn)", "cairn agent",        "mini_metric",  "cairn_health", "cairn_healthy"),
    ("Mac mini (cairn)", "iCloud backups",     "mini_backup_rollup", "cairn", "cairn_backup_last_rc"),

    # Appliances (probed via blackbox-exporter HTTPS — see
    # platform/kubernetes/blackbox-exporter/). namespace arg is unused
    # for kind="probe"; target is the `appliance` label.
    ("Appliances", "UDM",      "probe", "blackbox-exporter", "udm"),
    ("Appliances", "Protect",  "probe", "blackbox-exporter", "protect"),
    ("Appliances", "UNAS",     "probe", "blackbox-exporter", "unas"),
    ("Appliances", "Cue API (public)", "probe", "blackbox-exporter", "cue-api"),
]
