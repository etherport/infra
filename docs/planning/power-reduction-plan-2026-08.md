# Power reduction plan — unoccupied-house baseline

**Status:** 📋 plan; nothing applied yet. **Created 2026-08-19.**
**Driver:** $245.40/mo SCE bill with nobody at the house.

All figures below are **measured**, not estimated, unless marked. Rate is the real
blended marginal rate from the July 2026 bill: **$0.3185/kWh**. Rule of thumb:
**10 W saved = $2.29/month = $27.52/year.**

---

## 1. Where the money actually goes

| | kWh/day | Watts | $/mo |
|---|---|---|---|
| **Whole house** (bill: 672 kWh / 30 days) | 22.40 | **933** | $214 energy + $31 fixed |
| **The rack** (UPS-measured) | 10.42 | **~445** | **~$100** |
| Everything else (2 fridges + standby) | ~12 | ~490 | ~$115 |

**The rack is ~46% of household electricity.** There is no large hidden load — an
empty house drawing 933 W average is *low*. The rack is the story.

⚠️ **Earlier analysis in this session said the rack was ~25% and to look
elsewhere. That was wrong** — it assumed $0.20/kWh instead of the actual $0.3185,
which inflated the implied house usage. Corrected once the bill arrived.

### Rack breakdown

| Leg | Source | Watts | Notes |
|---|---|---|---|
| 1 (120 V) | UPS1 load 26% × 980 W | **265** | PDU1 (2.1 A × 120 V = 252 VA) agrees within 5% |
| 2 (208 V) | UPS2 **measured** | **180** | PDU2 implies 312 VA → power factor ≈ 0.58 |
| of which pve host | IPMI DCMI **measured** | **132** | the single largest item |
| of which rack PoE delivered | unpoller | 47 | switch's own draw is on top |
| unattributed | — | ~230 | NAS, UDM, mini, switch overhead, UPS losses |

⚠️ **PDU amps × volts is apparent power (VA), not watts.** Leg 1 agrees only
because its power factor happens to be ~1. Trust UPS watts where available.

---

## 2. Actions, best first

### 2.1 ✅ DO: fan tuning on the pve host — ~20-35 W, $5-8/mo, and fixes the noise

**The evidence is stark.** Fans are at near-maximum while the machine is cold:

```
FAN1 6000 RPM   FAN2-4 5800 RPM   PSU fans 5000-5200 RPM
CPU 59°C   motherboard 26°C   inlet 26°C   DDR5 32-34°C   GPU 29°C   PSU 28-29°C
```

Inlet and board at **26 °C** — there is enormous thermal headroom. Fan power scales
roughly with the **cube** of RPM, so halving speed cuts fan draw to about an eighth.
Four chassis fans at an estimated 6-10 W each is 24-40 W now; at ~3000 RPM that
becomes a few watts.

**ROOT CAUSE FOUND (2026-08-19): the Max-Duty clamp was never applied, or was lost.**
`FAN1` has not dropped below **5800 RPM at any point in 30 days** (`min_over_time`
over 1d/7d/14d/30d all return 5800-6000). A 40% clamp would sit near 2400-2600 RPM.
So the fans are running effectively unclamped.

The *other* half of the 2026-06-04 fix is intact and persistent: `disable-cpu-boost.service`
is enabled, `boost=0`, and `TEMP_CPU` is 59 °C — almost exactly the 57 °C that change
predicted. So the prerequisite for a low clamp is satisfied; only the clamp itself is missing.

**Known constraints on this board** (from the 2026-06-04 investigation, still valid):
- ASRock Rack **B650D4U**, AMI MegaRAC, BMC firmware **6.04** — *unchanged since that
  investigation*, so its conclusions still apply.
- The BMC curve keys off **`FSC_INDEX`** (PECI/Tctl-derived, reads ~10-14 °C above
  `TEMP_CPU`; currently 64 vs 59). The **Open Loop curve does NOT govern the fans.**
- The only effective lever is **Fan Mode → "Maximum Duty"**, set in the BMC web UI.
  Fan control was **not reachable via IPMI or Redfish** on this firmware.

**What is new:** the BMC does serve **Redfish 1.15.1** (AMI Redfish Server, Chassis
collection present) on `https://10.10.200.21`. That does not by itself mean fan control
is writable — AMI often exposes it only through OEM extensions — but it is worth
re-testing *with credentials* before accepting "web UI only". **There are no BMC
credentials in SOPS**, so this could not be tested.

**Recommended setting:** Fan Mode → Maximum Duty **50%** first, verify under real load
(not idle), then try **40%**. Expected ~2400-2900 RPM. Fan power scales with the cube of
RPM, so 6000 → 2600 RPM is roughly an eighth of current fan draw.

⚠️ **The PSU fans (5000-5200 RPM) are likely self-regulating and not BMC-governed**, so
the saving comes from the four chassis fans only — temper expectations accordingly.

⚠️ **Verify the live effect, don't trust the UI.** Watch `ipmi_fan_speed_rpm` in Grafana
after the change; if RPM does not fall, the clamp did not take — which is precisely how
this was missed for 30+ days.

### 2.2 ❌ DO NOT: spin down the NAS disks

Tempting (~40 W, $9/mo) and **wrong here**, on two grounds.

**It would not work.** The NAS is touched constantly: 12+ nightly CronJobs
(s3-sync ×7, github-mirror, rclone gdrive/onedrive, pve-config-offsite,
velero-dr-sync), **garage** — velero's primary backup repo, with its data blocks on
NFS — and Plex media. Conservatively ~60 accesses/day, spread across the clock.
Disks would spin up again within minutes of every spin-down.

**And it would damage the drives.** Spin-down/up cycles are the wear mechanism:
consumer HDDs are rated ~50,000 start/stop cycles. At ~60 cycles/day that is
**21,900/year — the rating consumed in about 2.3 years.** Continuous rotation is
gentler than frequent cycling. Spin-down only pays when idle windows are *hours*.

**If you want NAS savings**, the honest levers are fewer disks, larger/newer drives,
or moving the velero repo off it — not power management.

### 2.3 🤔 CONSIDER: retire what an empty house doesn't need

| Candidate | Watts | $/yr | Verdict |
|---|---|---|---|
| Tesla P40 GPU (idle) | 10.7 | $29 | Only worth it if ollama is genuinely unused. Idle cost is small; **it was NOT the villain** I earlier suspected. |
| Mac mini | ~15 est. | $41 | Its only job is cairn iCloud backups. Worth asking whether that justifies a always-on machine. |
| Plex | ~0 | — | Idle cost negligible; no saving in stopping it. |

Turning off *software* saves almost nothing — idle CPU is cheap. Only removing
**hardware** (or slowing fans) moves the needle.

### 2.4 ✅ ALREADY OPTIMAL: job scheduling

Nightly jobs run 00:00-01:10 PT, inside SCE's off-peak window (12am-4pm) at
$0.26107/kWh rather than the $0.58699 on-peak rate. Nothing to change.

---

## 3. What to measure next

1. **Confirm UPS1's nameplate** off the unit's label. Everything on leg 1 is derived
   from an assumed 980 W; the PDU cross-check supports it but does not prove it.
2. **Identify the remaining ~230 W** on the two legs. The NAS is the prime suspect
   and has no power telemetry. A single smart plug on its inlet would settle it.
3. **Whole-house circuit monitoring** (Emporia Vue / Shelly EM at the panel) if you
   want the other ~$115/mo attributed. The rack now self-reports; the house does not.

## 4. Realistic total

Fan tuning is the only large, safe, immediate win: **~$75/year**. Adding GPU and
mini retirement gets to roughly **$145/year** — but those remove capability.
Against a $2,945/year bill, the rack's ceiling is about $100/mo, and a realistic
reduction is 20-30% of that.
