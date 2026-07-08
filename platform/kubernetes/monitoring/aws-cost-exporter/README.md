# aws-cost-exporter (M136)

Daily AWS cost visibility so a cost/usage spike surfaces in **Grafana** and the
**daily service-status email** — not only via the single monthly AWS Budgets
forecast email.

**Why it exists:** an S3 `DataTransfer-Out` spike ran ~a week (forecast $75→$160)
and was caught only by a manual console check, because the sole cost signal was
the once-a-month budget-forecast email. This closes that visibility gap.

## How it works

1. **CronJob `aws-cost-exporter`** (05:30 PT, ~30m before the 06:00 status email)
   runs `aws-cost-exporter.py` as the `aws-cost-exporter` SA, which assumes IRSA
   role `wind-irsa-cloudwatch-read` (the `ReadCostExplorer` statement grants
   `ce:GetCostAndUsage`/`ce:GetCostForecast` + `budgets:*View/Describe`).
2. It makes **one** `ce:GetCostAndUsage` call (daily cost by service, 35-day
   window) + **one free** `budgets:DescribeBudget` call, and pushes `aws_cost_*`
   gauges to the cluster **Pushgateway**. CE cost ≈ **$0.30/mo**.
3. Prometheus scrapes Pushgateway → the metrics feed:
   - the **"AWS Cost" Grafana dashboard** (`dashboards/aws-cost.yaml`),
   - the **Cost section** of the daily email (`service-status-report.py`),
   - the **alerts** in `15-aws-cost-alerts.yaml`.

## Metrics

| Metric | Meaning |
|---|---|
| `aws_cost_mtd_usd` | month-to-date spend (Budgets) |
| `aws_cost_forecast_usd` | AWS forecasted month-end (Budgets) |
| `aws_cost_budget_usd` | configured monthly budget limit |
| `aws_cost_yesterday_usd` | spend for the most recent complete day |
| `aws_cost_service_mtd_usd{service}` | MTD by service (top 12) |
| `aws_cost_service_yesterday_usd{service}` | yesterday by service |
| `aws_cost_service_trailing7_avg_usd{service}` | trailing-7-day avg daily by service |
| `aws_cost_service_spike_ratio{service}` | yesterday ÷ 7-day-avg (>1 rising; emitted only above a $2/day floor) |
| `aws_cost_exporter_last_success_timestamp_seconds` | dead-man for `AWSCostExporterStale` |

## Alerts (`15-aws-cost-alerts.yaml`)

- **AWSCostForecastHigh** — forecast > budget (sustained-overage signal).
- **AWSServiceDailyCostSpike** — a service's day > 2× its 7-day avg (sudden-spike signal).
- **AWSCostExporterStale** — no push in >30h (pipeline dead-man).

## Manual run / debug

```bash
kubectl -n monitoring create job --from=cronjob/aws-cost-exporter cost-now
kubectl -n monitoring logs job/cost-now         # prints the pushed metric body
```

Deeper per-service / per-usage-type drill-down (e.g. isolating `DataTransfer-Out`
vs storage) needs the **claude-admin** Cost Explorer credential — the exporter is
scoped to the rollup metrics only.
