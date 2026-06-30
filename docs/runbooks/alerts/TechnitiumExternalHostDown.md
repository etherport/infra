# TechnitiumExternalHostDown

External Technitium DNS host (`dns-aws`, `dns-fallback`) unreachable for 1 minute
(`up{job="external-nodes",instance=~"dns-.*"} == 0`). Severity: critical. **No
auto-remediation** — this pages/emails only; it does NOT restart the in-cluster pods.

Renamed from `TechnitiumDNSDown` on 2026-06-30 to stop colliding with the in-cluster
alert of that name (which the auto-remediation controller `restart_pods` acts on). See
[`TechnitiumDNSDown.md`](TechnitiumDNSDown.md) — the external-host symptoms, root causes,
verification steps, and Tier-3 `restart_systemd_unit` guidance there still apply to this
alert.
