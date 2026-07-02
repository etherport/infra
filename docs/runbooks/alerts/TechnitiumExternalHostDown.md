# TechnitiumExternalHostDown

Local external Technitium DNS host (`dns-fallback`) unreachable for 1 minute
(`up{job="external-nodes",instance=~"dns-.*",location="local"} == 0`). Severity: critical.
**No auto-remediation** — this pages/emails only; it does NOT restart the in-cluster pods.

> **M110 (2026-07-02) coverage note — verified, no gap.** This rule is deliberately
> `location="local"`-scoped, so it only ever covered the LOCAL `dns-fallback` (10.10.201.6),
> not the AWS Technitium. The AWS DNS role now runs on the `vpn-aws` **edge box**
> (`location="aws"`, scraped at `10.10.100.10:9100`) — its **host**-down is covered by
> **`AWSReplicaHostDown`** (`up{...location="aws"}==0`), exactly as the former `dns-aws` was.
> Monitoring parity is preserved. ⚠️ **Pre-existing gap (NOT introduced by M110):** there is
> no DNS *query-level* probe (actual `:53` resolution) against the AWS Technitium — coverage
> is host-level only. Adding a blackbox `dns_query` probe is deferred (it would traverse the
> flaky WAN path from in-cluster; see M124).

Renamed from `TechnitiumDNSDown` on 2026-06-30 to stop colliding with the in-cluster
alert of that name (which the auto-remediation controller `restart_pods` acts on). See
[`TechnitiumDNSDown.md`](TechnitiumDNSDown.md) — the external-host symptoms, root causes,
verification steps, and Tier-3 `restart_systemd_unit` guidance there still apply to this
alert.
