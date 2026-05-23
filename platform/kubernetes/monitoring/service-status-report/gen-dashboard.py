#!/usr/bin/env python3
"""
Generate the service-status Grafana dashboard ConfigMap.

Reads the SERVICES list from services.py (single source of truth shared
with the email script) and writes the dashboard ConfigMap to
`platform/kubernetes/monitoring/dashboards/service-status.yaml`.

Usage:
    cd platform/kubernetes/monitoring/service-status-report
    python3 gen-dashboard.py            # writes the YAML in place
    python3 gen-dashboard.py --stdout   # prints to stdout (dry-run)

Re-run this after editing services.py and commit the regenerated
dashboard alongside the inventory change. A future CI workflow can
make this automatic; for now it's a one-line manual step.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from services import SERVICES  # noqa: E402


def query_for(kind, namespace, target):
    if kind == "deployment":
        return f'kube_deployment_status_replicas_available{{namespace="{namespace}",deployment="{target}"}}'
    if kind == "statefulset":
        return f'kube_statefulset_status_replicas_ready{{namespace="{namespace}",statefulset="{target}"}}'
    if kind == "daemonset":
        return f'kube_daemonset_status_number_ready{{namespace="{namespace}",daemonset="{target}"}}'
    if kind == "external":
        return f'up{{job="{namespace}",instance=~"{target}.*"}}'
    raise ValueError(kind)


TRACKED_DEPLOY = sorted({(ns, t) for _, _, k, ns, t in SERVICES if k == "deployment"})
TRACKED_STS    = sorted({(ns, t) for _, _, k, ns, t in SERVICES if k == "statefulset"})
TRACKED_DS     = sorted({(ns, t) for _, _, k, ns, t in SERVICES if k == "daemonset"})
TRACKED_EXT    = sorted({(ns, t) for _, _, k, ns, t in SERVICES if k == "external"})


def or_chain_avail():
    parts = []
    for ns, t in TRACKED_DEPLOY:
        parts.append(f'kube_deployment_status_replicas_available{{namespace="{ns}",deployment="{t}"}}')
    for ns, t in TRACKED_STS:
        parts.append(f'kube_statefulset_status_replicas_ready{{namespace="{ns}",statefulset="{t}"}}')
    for ns, t in TRACKED_DS:
        parts.append(f'kube_daemonset_status_number_ready{{namespace="{ns}",daemonset="{t}"}}')
    for ns, t in TRACKED_EXT:
        parts.append(f'up{{job="{ns}",instance=~"{t}.*"}}')
    return " or ".join(parts)


def stat_panel(panel_id, title, expr, gridPos, value_mappings, thresholds, reducer="lastNotNull"):
    return {
        "id": panel_id,
        "title": title,
        "type": "stat",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "gridPos": gridPos,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "mappings": value_mappings,
                "thresholds": thresholds,
                "unit": "none",
            },
            "overrides": [],
        },
        "options": {
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "center",
            "orientation": "auto",
            "reduceOptions": {"calcs": [reducer], "fields": "", "values": False},
            "showPercentChange": False,
            "textMode": "value_and_name",
            "wideLayout": True,
        },
        "pluginVersion": "11.0.0",
        "targets": [{
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "expr": expr,
            "legendFormat": "{{deployment}}{{statefulset}}{{daemonset}}{{instance}}",
            "refId": "A",
        }],
    }


def text_panel(panel_id, content, gridPos):
    return {
        "id": panel_id,
        "title": "",
        "type": "text",
        "gridPos": gridPos,
        "options": {"mode": "markdown", "content": content},
    }


def build_dashboard():
    panels = []
    pid = 1

    avail = or_chain_avail()
    total = len(SERVICES)

    # Top row: 4 counters
    panels.append(stat_panel(pid, "Healthy", f"count(({avail}) > 0)",
                             {"h": 5, "w": 6, "x": 0, "y": 0}, [],
                             {"mode": "absolute", "steps": [
                                 {"color": "red", "value": None},
                                 {"color": "green", "value": 1}]})); pid += 1
    panels.append(stat_panel(pid, "Down", f"count(({avail}) == 0)",
                             {"h": 5, "w": 6, "x": 6, "y": 0}, [],
                             {"mode": "absolute", "steps": [
                                 {"color": "green", "value": None},
                                 {"color": "red", "value": 1}]})); pid += 1
    panels.append(stat_panel(pid, "Unknown (no metric)",
                             f"{total} - count({avail})",
                             {"h": 5, "w": 6, "x": 12, "y": 0}, [],
                             {"mode": "absolute", "steps": [
                                 {"color": "green", "value": None},
                                 {"color": "orange", "value": 1}]})); pid += 1
    panels.append(stat_panel(pid, "Firing alerts",
                             'count(ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"})',
                             {"h": 5, "w": 6, "x": 18, "y": 0}, [],
                             {"mode": "absolute", "steps": [
                                 {"color": "green", "value": None},
                                 {"color": "orange", "value": 1},
                                 {"color": "red", "value": 5}]})); pid += 1

    # Per-category panel rows
    y = 5
    PANEL_W = 6
    PANEL_H = 4
    HEADER_H = 2

    SVC_THRESHOLDS = {"mode": "absolute", "steps": [
        {"color": "red", "value": None},
        {"color": "green", "value": 1},
    ]}
    SVC_MAPPINGS = [
        {"type": "value", "options": {str(n): {"text": "UP", "color": "green"}
                                      for n in range(1, 11)}},
        {"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}}},
        {"type": "special", "options": {"match": "null",
                                        "result": {"text": "UNKNOWN", "color": "orange"}}},
    ]

    seen_cats = []
    for cat, _, _, _, _ in SERVICES:
        if cat not in seen_cats:
            seen_cats.append(cat)

    for cat in seen_cats:
        panels.append(text_panel(pid, f"### {cat}",
                                 {"h": HEADER_H, "w": 24, "x": 0, "y": y})); pid += 1
        y += HEADER_H
        cat_svcs = [(n, k, ns, t) for c, n, k, ns, t in SERVICES if c == cat]
        for idx, (name, kind, ns, target) in enumerate(cat_svcs):
            col = idx % 4
            row = idx // 4
            panels.append(stat_panel(pid, name, query_for(kind, ns, target),
                                     {"h": PANEL_H, "w": PANEL_W,
                                      "x": col * PANEL_W, "y": y + row * PANEL_H},
                                     SVC_MAPPINGS, SVC_THRESHOLDS)); pid += 1
        y += ((len(cat_svcs) - 1) // 4 + 1) * PANEL_H

    # Firing-alerts table
    firing = {
        "id": pid,
        "title": "Firing alerts",
        "type": "table",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "gridPos": {"h": 8, "w": 24, "x": 0, "y": y + 1},
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "custom": {"align": "left", "displayMode": "auto"},
                "mappings": [],
                "thresholds": {"mode": "absolute", "steps": [{"color": "green"}]},
            },
            "overrides": [
                {"matcher": {"id": "byName", "options": "severity"},
                 "properties": [
                     {"id": "custom.cellOptions", "value": {"type": "color-text"}},
                     {"id": "mappings", "value": [
                         {"type": "value", "options": {
                             "critical": {"text": "critical", "color": "red"},
                             "warning":  {"text": "warning",  "color": "orange"},
                             "info":     {"text": "info",     "color": "blue"},
                         }},
                     ]},
                 ]},
            ],
        },
        "options": {"showHeader": True, "footer": {"show": False}},
        "pluginVersion": "11.0.0",
        "targets": [{
            "datasource": {"type": "prometheus", "uid": "prometheus"},
            "expr": 'ALERTS{alertstate="firing",alertname!~"Watchdog|InfoInhibitor"}',
            "instant": True, "format": "table", "refId": "A",
        }],
        "transformations": [
            {"id": "filterFieldsByName",
             "options": {"include": {"names": [
                 "alertname", "severity", "namespace", "instance", "alertstate"]}}},
        ],
    }
    panels.append(firing)
    pid += 1

    return {
        "annotations": {"list": []},
        "editable": True,
        "fiscalYearStartMonth": 0,
        "graphTooltip": 0,
        "links": [],
        "panels": panels,
        "refresh": "1m",
        "schemaVersion": 39,
        "tags": ["status", "homelab"],
        "templating": {"list": []},
        "time": {"from": "now-1h", "to": "now"},
        "timepicker": {},
        "timezone": "America/Los_Angeles",
        "title": "Service Status",
        "uid": "service-status",
        "version": 1,
        "weekStart": "",
    }


def wrap_in_configmap(dash_json: str) -> str:
    indented = "\n".join("    " + line for line in dash_json.splitlines())
    return (
        "# AUTO-GENERATED by service-status-report/gen-dashboard.py\n"
        "# Edit services.py and re-run that script to refresh this file.\n"
        "apiVersion: v1\n"
        "kind: ConfigMap\n"
        "metadata:\n"
        "  name: service-status-dashboard\n"
        "  namespace: monitoring\n"
        "  labels:\n"
        "    grafana_dashboard: \"1\"\n"
        "data:\n"
        "  service-status.json: |\n"
        f"{indented}\n"
    )


def main():
    dash = build_dashboard()
    dash_json = json.dumps(dash, indent=2)
    yaml_out = wrap_in_configmap(dash_json)

    if "--stdout" in sys.argv[1:]:
        sys.stdout.write(yaml_out)
        return

    # Default: write to ../dashboards/service-status.yaml
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.realpath(os.path.join(here, "..", "dashboards", "service-status.yaml"))
    with open(target, "w") as f:
        f.write(yaml_out)
    print(f"wrote {target} ({len(yaml_out)} bytes, {len(dash['panels'])} panels)")


if __name__ == "__main__":
    main()
