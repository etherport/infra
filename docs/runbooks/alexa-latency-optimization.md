# Alexa → Home Assistant latency optimization

Knobs to pull if voice-to-action delay feels slow. Listed in order of
impact-per-effort. Captured 2026-05-27 during the ALB → CF Tunnel
migration; the latency math compares the two paths.

## Path comparison

### Old (ALB)
```
Alexa cloud → Lambda (us-east-1)
  → DNS → ALB (us-west-2)              ~65-80 ms cross-region inside AWS
  → ALB → home cluster (AWS VPN)        variable
  → Traefik → HA pod
```
Biggest cost was the **cross-region trip**: Lambda must be in
`us-east-1` for Alexa Smart Home, but the ALB lived in `us-west-2`.

### New (CF Tunnel)
```
Alexa cloud → Lambda (us-east-1)
  → DNS → CF anycast (Lambda lands at IAD POP)    ~2-5 ms
  → CF edge → cloudflared (existing QUIC connection) ~10-30 ms
  → cloudflared pod → HA service                    ~1-2 ms
```
CF Access service-token verification adds ~5-10 ms on the hot path.
Net: expected **30-100 ms faster** than the ALB path.

## Measuring

```bash
aws --profile homelab --region us-east-1 logs tail \
  /aws/lambda/homeassistant-alexa --follow
```

Trigger "Alexa, turn on the living room" with Lambda warm; the
`Duration:` line in each REPORT entry is end-to-end Lambda time.
Run 10x to stabilize.

Cold-start vs warm-start: first invocation after idle is 100-300 ms
slower. The "felt" latency you experience is almost always **cold-start
penalty**, not network distance.

## Optimization knobs (highest impact first)

### 1. Lambda provisioned concurrency — single biggest win (~$3/mo)

Eliminates cold-start entirely by keeping one Lambda instance always
initialized. The 100-300 ms cold-start penalty dominates user-perceived
latency on infrequently-invoked Alexa skills.

In `infra/terraform/aws/homeassistant-alexa/main.tf`:

```hcl
resource "aws_lambda_provisioned_concurrency_config" "ha" {
  function_name                     = aws_lambda_function.homeassistant_alexa.function_name
  qualifier                         = aws_lambda_function.homeassistant_alexa.version
  provisioned_concurrent_executions = 1
}
```

Requires publishing a Lambda version (set `publish = true` on the
function). Cost: ~$0.0000041667 per GB-sec × 128 MB × 86400 × 30 ≈
**$3-4/mo** for a 128 MB function.

### 2. Argo Smart Routing — ~20-30 ms on CF backbone routing

$5/mo + $0.10/GB on top of the etherport.net zone. CF routes through
its optimized backbone instead of generic transit. For Alexa-level
volume (Lambda → CF → home, maybe MBs/month) the per-GB charge is
negligible — effectively $5/mo flat.

Enable: CF dashboard → etherport.net → Traffic → Argo Smart Routing →
On. No code change.

Worth it if Lambda CloudWatch Duration is consistently >150 ms after
provisioned concurrency.

### 3. Increase Lambda memory — improves CPU proportionally

AWS gives more CPU at higher memory tiers. JSON parsing, HTTP
overhead, urllib3 setup all benefit. Marginal additional cost.

In `main.tf`:
```hcl
memory_size = 512   # was 128
```

Real-world gain: 20-40 ms on warm invocations.

### 4. Skip CF Access on the API endpoint (security trade-off)

Narrow the HA Access policy to UI paths only, leaving
`/api/alexa/smart_home` unprotected. Saves the service-token
verification step on the hot path (~5-10 ms).

Trade-off: that endpoint becomes "anyone reaching it via HTTPS can
attempt to authenticate with an HA bearer token." Still gated by HA's
own bearer-token auth — same as if Alexa Lambda hit HA directly. But
loses CF Access as the outer defense layer for THAT endpoint.

For low-stakes home automation it's an acceptable simplification;
for environments where HA controls more sensitive things (locks,
garage doors), keep the full Access policy in place.

To configure: edit `cloudflare_zero_trust_access_application.ha`
in `infra/terraform/cloudflare/alexa-service-token.tf` — set the
`path_cookie` field or use multiple Access apps with different
include/exclude path patterns.

### 5. Cloudflared replica placement — marginal

Currently 2 cloudflared replicas (`platform/kubernetes/cloudflared/`)
on whatever nodes Cilium schedules them. Could pin them to nodes with
the best home-LAN routing via a `nodeSelector`. Real-world gain on a
small cluster: probably <5 ms.

Bumping to 3 replicas adds redundancy + minor latency improvement (CF
edge picks the lowest-RTT connection). Cost: small CPU/memory.

## Recommended order

1. **Provisioned concurrency** — most impact, cheap, safe
2. Measure for a few days — if still feels slow, add **Argo Smart Routing**
3. If still tight after Argo, **bump Lambda memory** to 512 MB
4. Only consider #4 (skip Access on API path) if every ms matters AND
   you're comfortable with the security trade-off

## Cold start floor

Even with all optimizations, **first invocation after >15 min idle**
will be slower because:
- AWS may reclaim the Lambda execution environment despite provisioned
  concurrency (rare but happens)
- CF Tunnel might need to renegotiate if a cloudflared pod restarts
- HA itself may need to load any cached state

Realistic best-case for a warm, optimized Alexa-to-HA round trip: **80-150 ms
network + Lambda + HA total**. Voice → device-state-change is bounded by
that.
