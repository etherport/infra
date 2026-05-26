# PveCpuTempHigh

Fires when `ipmi_temperature_celsius{name="TEMP_CPU"} > 80` for 5
minutes on the PVE host. Severity: warning. No auto-action (hardware).

## Symptom

PrometheusRule `pve-ipmi.rules / PveCpuTempHigh` firing on `pve`. CPU
sustained above 80°C — early warning before BMC SEL assertion (sensor
unc=82) or the critical 88°C / TjMax 95°C thresholds.

## Verified root cause(s)

- Fan curve in BMC UI too lazy for sustained load — fans aren't ramping
  in time. This was the 2026-05-02 incident pattern: brief spikes to
  98°C with fans not ramping in time, repeating every few hours.
- High ambient room temperature (summer / HVAC issue) — pairs with
  `PveFansPegged`.
- A specific workload pinning a core at 100% (rebuild jobs, gpu-burn,
  unattended ZFS scrub on a hot day).
- Failed fan reducing total cooling capacity — pairs with `PveFanFailed`.

## Fix history

- 2026-05-23 (commit 202b9b3): Initial M40 wiring of ipmi_exporter +
  ipmievd + tighter BMC thresholds (unc=82, ucr=90, was at-thermal-throttle
  98/99). Closes the operational blind spot from the 2026-05-02
  incident.
- 2026-05-23 (commit 43c07fe): Removed a LogQL rule that had been
  mixed into the same PrometheusRule group — unrelated to the alert
  semantics, but it had blocked the rule's reconcile briefly.

## Verification steps

1. Current temp + history in Grafana via the `nvidia-gpu-dashboard.yaml`
   neighbor or any node-exporter dashboard with ipmi panels added.
2. Direct via ipmi-exporter scrape:
   `ipmi_temperature_celsius{job="pve-ipmi",name="TEMP_CPU"}`
3. SEL events (matches BMC's view):
   In Loki: `{app="ipmievd", host="pve"} |~ "Asserted"`
4. After fan-curve tune, sustained-load test (e.g., `stress-ng --cpu 8`)
   should hold temp below the threshold.

## Advisor action guidance

- This is a hardware alert — no remediation in the advisor's action
  set will fix it. Correct outcome: `noop` with detailed diagnostic
  (current temp, fan RPMs, recent SEL events, suspect workload).
- The advisor should NOT propose `restart_pods` or `rollout_restart`
  on workloads even if it identifies a "hot" pod — the operator gets
  to decide whether to migrate workload vs. retune fan curve.
- A future enhancement could add an `adjust_fan_curve` Ansible action,
  but it doesn't exist today.
