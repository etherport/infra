#!/usr/bin/env python3
"""
aws-cost-exporter (M136) — daily AWS cost visibility.

Runs once/day (before the 06:00 service-status email), reads AWS cost data via
IRSA (role wind-irsa-cloudwatch-read), and pushes gauges to the cluster
Pushgateway so both Grafana AND the daily status email can render:
  - month-to-date spend + AWS's forecasted month-end (from AWS Budgets — free)
  - per-service month-to-date breakdown (Cost Explorer)
  - yesterday's spend, per-service, + a trailing-7-day average per service
  - a per-service spike ratio (yesterday / trailing-7d-avg) so a usage/egress
    spike surfaces the SAME day instead of only via the monthly budget email.

Cost of running this: ONE ce:GetCostAndUsage call/day ($0.01) + one free
budgets:DescribeBudget call ≈ $0.30/mo. Cheap insurance against a $100+ spike
running unnoticed for weeks (the S3 DataTransfer-Out incident that motivated M136).

Env:
  PUSHGATEWAY        host:port of the Pushgateway (default monitoring svc)
  BUDGET_NAME        AWS Budgets budget to read (default homelab-monthly)
  COST_REGION        region for the CE/Budgets endpoint (default us-east-1)
  TOP_SERVICES       how many services to emit per-service metrics for (default 12)
"""
import os
import sys
import time
import datetime
import urllib.request

import boto3

PUSHGATEWAY = os.environ.get("PUSHGATEWAY", "pushgateway.monitoring.svc.cluster.local:9091")
BUDGET_NAME = os.environ.get("BUDGET_NAME", "homelab-monthly")
COST_REGION = os.environ.get("COST_REGION", "us-east-1")
ACCOUNT_ID = os.environ.get("AWS_ACCOUNT_ID", "830881980142")
TOP_SERVICES = int(os.environ.get("TOP_SERVICES", "12"))
PUSH_JOB = "aws_cost_exporter"

# Alert/label tuning — a service's "spike" is meaningful only above an absolute
# floor (so cent-level services don't flap) AND a ratio vs its own trailing avg.
SPIKE_MIN_USD_PER_DAY = float(os.environ.get("SPIKE_MIN_USD_PER_DAY", "2.0"))


def _today_utc():
    # CE uses date strings; "today" is exclusive as an End date.
    return datetime.datetime.now(datetime.timezone.utc).date()


def fetch_budget(region):
    """MTD actual + forecasted month-end + limit from AWS Budgets (free, matches console)."""
    b = boto3.client("budgets", region_name=region)
    try:
        resp = b.describe_budget(AccountId=ACCOUNT_ID, BudgetName=BUDGET_NAME)["Budget"]
    except Exception as e:  # noqa: BLE001
        print(f"[warn] describe_budget failed: {e}", file=sys.stderr)
        return {}
    out = {}
    lim = resp.get("BudgetLimit") or {}
    if lim.get("Amount"):
        out["budget"] = float(lim["Amount"])
    cs = resp.get("CalculatedSpend") or {}
    if cs.get("ActualSpend", {}).get("Amount"):
        out["mtd"] = float(cs["ActualSpend"]["Amount"])
    if cs.get("ForecastedSpend", {}).get("Amount"):
        out["forecast"] = float(cs["ForecastedSpend"]["Amount"])
    return out


def fetch_ce_daily_by_service(region, days=35):
    """One CE call: daily UnblendedCost grouped by SERVICE for the trailing `days`."""
    ce = boto3.client("ce", region_name=region)
    end = _today_utc()
    start = end - datetime.timedelta(days=days)
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )
    # daily[date_str][service] = amount
    daily = {}
    for r in resp["ResultsByTime"]:
        d = r["TimePeriod"]["Start"]
        row = daily.setdefault(d, {})
        for g in r["Groups"]:
            amt = float(g["Metrics"]["UnblendedCost"]["Amount"])
            if amt:
                row[g["Keys"][0]] = amt
    return daily


def summarize(daily):
    """Derive MTD-by-service, yesterday-by-service, trailing-7d avg, spike ratios."""
    days = sorted(daily.keys())
    if not days:
        return {}
    today = _today_utc()
    month_prefix = today.strftime("%Y-%m-")

    services = set()
    for row in daily.values():
        services.update(row.keys())

    mtd = {s: 0.0 for s in services}
    for d, row in daily.items():
        if d.startswith(month_prefix):
            for s, a in row.items():
                mtd[s] += a

    # "yesterday" = the most recent COMPLETE day CE has (last key). CE's latest
    # day is often partial; use the last-but-nothing-newer day as the signal.
    yday_key = days[-1]
    yday = dict(daily.get(yday_key, {}))

    # trailing 7 complete days BEFORE yesterday (days[-8:-1]).
    window = days[-8:-1] if len(days) >= 8 else days[:-1]
    avg7 = {s: 0.0 for s in services}
    for d in window:
        for s, a in daily[d].items():
            avg7[s] = avg7.get(s, 0.0) + a
    n = max(1, len(window))
    avg7 = {s: v / n for s, v in avg7.items()}

    spike = {}
    for s in services:
        y = yday.get(s, 0.0)
        base = avg7.get(s, 0.0)
        if y >= SPIKE_MIN_USD_PER_DAY:
            ratio = (y / base) if base > 0.01 else (y / SPIKE_MIN_USD_PER_DAY)
            spike[s] = ratio
    return {
        "mtd": mtd,
        "yesterday": yday,
        "yesterday_date": yday_key,
        "avg7": avg7,
        "spike": spike,
        "mtd_total": sum(mtd.values()),
        "yesterday_total": sum(yday.values()),
    }


def esc(v):
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def build_metrics(budget, summ):
    lines = []

    def g(name, value, help_text, labels=None):
        lines.append(f"# HELP {name} {help_text}")
        lines.append(f"# TYPE {name} gauge")
        if labels:
            lbl = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
            lines.append(f"{name}{{{lbl}}} {value}")
        else:
            lines.append(f"{name} {value}")

    if "mtd" in budget:
        g("aws_cost_mtd_usd", budget["mtd"], "AWS month-to-date spend (USD, from Budgets)")
    elif summ:
        g("aws_cost_mtd_usd", round(summ["mtd_total"], 4), "AWS month-to-date spend (USD, CE-summed)")
    if "forecast" in budget:
        g("aws_cost_forecast_usd", budget["forecast"], "AWS forecasted month-end spend (USD, from Budgets)")
    if "budget" in budget:
        g("aws_cost_budget_usd", budget["budget"], "Configured monthly budget limit (USD)")

    if summ:
        g("aws_cost_yesterday_usd", round(summ["yesterday_total"], 4),
          "AWS spend for the most recent complete day (USD)")
        # top-N services by MTD
        top = sorted(summ["mtd"].items(), key=lambda kv: -kv[1])[:TOP_SERVICES]
        # HELP/TYPE only once per metric family
        lines.append("# HELP aws_cost_service_mtd_usd AWS month-to-date spend by service (USD)")
        lines.append("# TYPE aws_cost_service_mtd_usd gauge")
        for svc, amt in top:
            lines.append(f'aws_cost_service_mtd_usd{{service="{esc(svc)}"}} {round(amt, 4)}')
        lines.append("# HELP aws_cost_service_yesterday_usd AWS spend yesterday by service (USD)")
        lines.append("# TYPE aws_cost_service_yesterday_usd gauge")
        for svc, _ in top:
            lines.append(f'aws_cost_service_yesterday_usd{{service="{esc(svc)}"}} {round(summ["yesterday"].get(svc,0.0),4)}')
        lines.append("# HELP aws_cost_service_trailing7_avg_usd AWS trailing-7-day avg daily spend by service (USD)")
        lines.append("# TYPE aws_cost_service_trailing7_avg_usd gauge")
        for svc, _ in top:
            lines.append(f'aws_cost_service_trailing7_avg_usd{{service="{esc(svc)}"}} {round(summ["avg7"].get(svc,0.0),4)}')
        lines.append("# HELP aws_cost_service_spike_ratio yesterday / trailing-7d-avg per service (>1 = rising)")
        lines.append("# TYPE aws_cost_service_spike_ratio gauge")
        for svc, ratio in sorted(summ["spike"].items(), key=lambda kv: -kv[1])[:TOP_SERVICES]:
            lines.append(f'aws_cost_service_spike_ratio{{service="{esc(svc)}"}} {round(ratio,3)}')

    g("aws_cost_exporter_last_success_timestamp_seconds", int(time.time()),
      "Unix time of the last successful cost export (dead-man for AWSCostExporterStale)")
    return "\n".join(lines) + "\n"


def push(body):
    url = f"http://{PUSHGATEWAY}/metrics/job/{PUSH_JOB}"
    req = urllib.request.Request(url, data=body.encode(), method="PUT",
                                 headers={"Content-Type": "text/plain"})
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status not in (200, 202):
            raise RuntimeError(f"pushgateway returned {r.status}")
    print(f"[ok] pushed cost metrics to {url}")


def main():
    budget = fetch_budget(COST_REGION)
    try:
        daily = fetch_ce_daily_by_service(COST_REGION)
        summ = summarize(daily)
    except Exception as e:  # noqa: BLE001
        print(f"[warn] Cost Explorer query failed: {e}", file=sys.stderr)
        summ = {}
    if not budget and not summ:
        print("ERROR: both Budgets and Cost Explorer failed; nothing to push", file=sys.stderr)
        sys.exit(1)
    body = build_metrics(budget, summ)
    print(body)
    push(body)
    if summ:
        hot = sorted(summ["spike"].items(), key=lambda kv: -kv[1])[:3]
        print(f"[info] MTD ${summ['mtd_total']:.2f} | yesterday ${summ['yesterday_total']:.2f} "
              f"({summ['yesterday_date']}) | top spikes {hot}")


if __name__ == "__main__":
    main()
