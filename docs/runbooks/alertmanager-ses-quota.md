# AlertmanagerFailedToSendAlerts — AWS SES Quota Exhaustion

## Issue

**First observed**: 2026-05-16 ~02:09 UTC
**Status**: Transient (provider-side rate/quota limit)
**Receiver**: `monitoring/email-notifications/email-alerts` (AWS SES SMTP, `email-smtp.us-west-2.amazonaws.com:587`)

### Symptoms

Alertmanager pod (`alertmanager-monitoring-kube-prometheus-alertmanager-{0,1}`) emits
`AlertmanagerFailedToSendAlerts` because every email notification is rejected by SES with SMTP 454.

### Signature log lines

```
level=WARN  msg="Notify attempt failed, will retry later"
  receiver=monitoring/email-notifications/email-alerts integration=email[0]
  err="delivery failure: 454 Throttling failure: Daily message quota exceeded."

level=ERROR msg="Notify for alerts failed"
  err="...notify retry canceled after 15 attempts:
       delivery failure: 454 Throttling failure: Daily message quota exceeded."

# (occasional, when retry storm bursts)
err="delivery failure: 454 Throttling failure: Maximum sending rate exceeded."
```

Distribution observed over the 6h window: 54x "Daily message quota exceeded",
1x "Maximum sending rate exceeded".

## Root Cause

AWS SES is enforcing the account-level **24-hour sending quota** (sandbox/low-tier limit,
typically 200 msg/24h for unverified accounts, 50k+ once production access is granted).
The SES SMTP endpoint returns SMTP code 454 with the throttling reason, which Alertmanager
treats as a retriable failure and re-attempts — driving the burst rate limit too.

Confirmation that this is provider-side (not config, DNS, auth, or TLS):

- TCP/TLS handshake succeeded (no `dial`/`tls`/`x509`/`no such host` errors in logs).
- SMTP AUTH succeeded; SES only rejects after `MAIL FROM` with 454.
- The same SMTP credentials (SES IAM user `AKIA4C5DM33XKE5WUPG4`) are still valid —
  no `535 Authentication Credentials Invalid`.
- Inflated alert volume earlier in the day drained the daily quota; top drivers
  by aggregation group in the logs:
  - `AlertmanagerFailedToSendAlerts` (self-amplifying, 42 retries)
  - `InfoInhibitor` namespace=wireguard (20)
  - `KubeJobFailed` namespace=cloudflare-ddns (8)

## Fix

**No code or secret change is required.** The condition self-clears at the start of the
next SES 24-hour rolling window. Alertmanager's retry/dedup will deliver the pending
groups (`groupInterval=5m`, `repeatInterval=4h`) once the quota frees up.

### Immediate verification

```bash
export AWS_PROFILE=claude-admin   # needs ses:GetSendQuota; homelab profile lacks it
aws ses get-send-quota --region us-west-2
# Look at SentLast24Hours vs Max24HourSend
```

### If it recurs

1. **Request SES production access** (one-time, lifts cap to 50k/day):
   AWS Console → SES → Account dashboard → Request production access.
2. **Quiet the noisiest alerts** to keep daily volume well below the cap. The
   `InfoInhibitor` and `cloudflare-ddns` `KubeJobFailed` groups dominated this incident;
   tune their `for:` durations or add inhibition rules in
   `platform/kubernetes/monitoring/03-alertmanager-config.yaml`.
3. **Do not** rotate the SMTP credentials — 454 is not an auth failure, and rotation
   will not change SES quota.

## Files

- AlertmanagerConfig: `platform/kubernetes/monitoring/03-alertmanager-config.yaml`
- SMTP secret (SOPS): `platform/kubernetes/monitoring/alertmanager-secret.sops.yaml`
- HelmRelease values: `clusters/wind/helm-releases/monitoring.yaml`
