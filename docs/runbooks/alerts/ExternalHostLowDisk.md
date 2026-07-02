# ExternalHostLowDisk

Fires when filesystem usage on an external (non-K8s) host exceeds 80%
for 5 minutes. Severity: warning. Labeled `ai_remediation: "auto"` —
auto-eligible action: `prune_host_logdir` (Tier 3 SSH).

## Symptom

PrometheusRule `external-hosts.rules / ExternalHostLowDisk` firing on
a Tier 3 SSH-managed host (`dns-fallback`, `vpn-fallback`, `vpn-aws`).
Most commonly a Technitium host — since M110 the AWS edge box `vpn-aws`
runs Technitium (the former separate `dns-aws` box was destroyed), so
query logs accumulate in `/opt/technitium/config/logs/` and
`/opt/technitium/config/stats/` and can fill a small EBS volume in days.

## Verified root cause(s)

- Technitium DNS query-log accumulation on the edge box (vpn-aws) /
  dns-fallback — the documented 2026-05-25 pattern that motivated wiring
  `prune_host_logdir` to this alert.
- Journald accumulation — large `/var/log/journal/` directory on hosts
  with verbose units. Cleared via `journal_vacuum`.
- An app-specific logdir filling (wireguard handshake logs on
  vpn-aws, etc.) — same pattern, different path.
- Real disk-pressure from a workload (e.g., a large file landed in
  `/tmp` or `/var/lib`) — NOT auto-remediable; needs operator.

## Fix history

- 2026-05-25 (commit 69ff28d): Initial wiring of `prune_host_logdir`
  and `journal_vacuum` Tier 3 SSH actions plus the `ai_remediation:
  "auto"` label on this alert. Defense-in-depth via remote-side
  wrapped script + Cmnd_Alias'd sudo so even hallucinated parameters
  get rejected.

## Verification steps

1. Confirm filesystem pressure from outside (Prometheus):
   `(1 - (node_filesystem_avail_bytes{job="external-nodes",instance="<host>"} / node_filesystem_size_bytes{...})) * 100`
2. SSH and identify the culprit directory:
   `ssh <host> sudo du -sh /opt/technitium/config/logs/ /opt/technitium/config/stats/ 2>/dev/null | sort -h`
3. After action, watch the metric drop:
   `node_filesystem_avail_bytes{instance="<host>"}` should jump up
   within one scrape interval.
4. Audit log entry should exist in Loki:
   `{namespace="auto-remediation"} |= "prune_host_logdir"`

## Advisor action guidance

- Auto-eligible: `prune_host_logdir(host=<name>, logdir_key=technitium-logs|technitium-stats, days=<n>)`.
  `logdir_key` is an enum the wrapper maps to a fixed directory
  (`technitium-logs` → `/opt/technitium/config/logs`, `technitium-stats`
  → `/opt/technitium/config/stats`) — there is no free-form path param,
  so arbitrary paths are structurally impossible (not merely rejected by
  a prefix allowlist). A host allowlist still bounds the SSH target.
- Auto-eligible: `journal_vacuum(host=<name>, retain_days=<n>)` when
  `journalctl --disk-usage` indicates journal is the culprit.
- `restart_systemd_unit` is allowed-but-manual — disruptive, use only
  when the culprit unit is wedged and a vacuum/prune wasn't enough.
- `noop` + operator recommendation when culprit isn't in the
  prune-allowlist (e.g., a large file in `/tmp` or app data).
