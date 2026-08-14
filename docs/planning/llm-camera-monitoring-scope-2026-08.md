# Scoping brief — LLM-assisted camera / security-activity monitoring

**Status:** 📋 scoping only — nothing built, nothing decided.
**Created:** 2026-08-14. **Owner ask:** "investigate LLM alerts / monitoring for home
camera / security system activity."

This document exists so a fresh agent or thread can pick the work up with real facts
instead of a summary. Everything in the "What exists today" section was **verified live
on 2026-08-14**, not recalled. Verify again before relying on it — this is a
point-in-time snapshot.

---

## 1. The goal, stated as questions

The ask is broad, so the first job is narrowing it. Candidate framings, which imply very
different systems:

1. **Better alerts from existing detections** — Protect already detects person/vehicle/
   package. An LLM summarises/prioritises/suppresses, e.g. "3 person events at the gate
   between 02:00–02:30, same individual, lingering" instead of 3 raw notifications.
2. **Semantic understanding of footage** — a vision model looks at snapshots/clips and
   answers questions Protect cannot ("is that a delivery or someone trying handles?").
3. **Cross-source correlation** — fuse camera events with door/motion sensors in Home
   Assistant, UDM firewall/DHCP events, and Tetragon/host telemetry into one narrative.
4. **Natural-language query over history** — "was anyone at the side gate last Tuesday
   evening?"

**These are not the same project.** (1) is a text-only problem and largely buildable with
what is already running. (2) needs a vision model and a frame pipeline. (4) needs
retention and an index. Pick before designing.

---

## 2. What exists today (verified 2026-08-14)

### Cameras / NVR
- **UniFi Protect — `Windprotect` at `10.10.212.10`** (VLAN 212).
- **API access is READ-ONLY** via the `protect-tf` integration key.
  ⚠️ **Alarm Manager automations are UI-only** — they cannot be created or changed
  through the API or Terraform. Any design that assumes IaC-managed Protect automations
  is wrong; a human clicks those.
- ⚠️ **Protect's webhook client is BROKEN for hostnames.** Webhook URLs must be
  **IP-literal plain HTTP** (`http://10.10.201.70:8088/api/webhook/<id>`) — hostname URLs
  fail with `ERR_INVALID_IP_ADDRESS`, and it validates TLS so https-by-IP fails too.
  Served today by a dedicated Traefik `webhook` entrypoint
  (`platform/kubernetes/home-automation/ingressroute-webhook.yaml`). **This is the
  existing, working camera→cluster event path and the obvious foundation to build on.**
- SSH to the Protect host uses `udm_ssh_user` / `udm_ssh_password` from the SOPS bundle.
- ⚠️ **The `protect-tf` integration key is NOT in the SOPS bundle** (contrary to what the
  agent brief assumed) — it exists only in 1Password; adding it to SOPS is a still-open
  optional item (outstanding-work ~L699, session-log 2026-06-15). Headless enumeration
  below was done **read-only via SSH + the Protect PostgreSQL** instead (instance
  `/srv/postgresql/14/protect`, port `5433`, socket `/var/run/postgresql`, db
  `unifi-protect` — `psql -U postgres` as root works). A production integration should
  get the key into SOPS rather than lean on root SSH + DB reads.

### Camera inventory (enumerated 2026-08-14, from the Protect DB)

**13 adopted devices** — 12 cameras + 1 doorbell/intercom — on VLAN 212, all recording
mode **`always`**, all on firmware 5.4.122 (intercom 1.11.23.0). Protect **7.1.87** on a
UNVR (aarch64). One additional **stale unadopted** `cameras` row ("Access Road", MAC
`28704E16EBAA`, last seen 2026-04-04) is a replaced unit — ignore it.

| Camera | Model | IP | Max stream | Smart detections enabled |
|---|---|---|---|---|
| Access Road | **UVC AI Pro** | .226 | 3840×2160@30 h264 | person, vehicle, animal, **face**, **licensePlate** + 9 audio types |
| Gate | **UVC AI Pro** | .172 | 3840×2160@30 h265 | person, vehicle, animal, **face**, **licensePlate** + 10 audio types |
| Path | UVC G5 Bullet | .107 | 2688×1512@30 h264 | person, vehicle, animal + smoke/CO/baby-cry audio |
| Driveway Mid | UVC G4 Bullet | .103 | 2688×1512@24 h265 | person, vehicle, animal + audio; `videoMode: lprNoneReflex` (LPR-assist) |
| Basement, Chapel, Deck, Driveway Lower, Driveway Upper, Front Door, Living Room, Workroom | UVC G4 Bullet ×8 | .111/.108/.110/.109/.105/.104/.106/.125 | 2688×1512@24 h265 | person, vehicle (animal-capable, not enabled) |
| Driveway Gate - Entry | UA Intercom | .115 | 1200×1600@30 h264 | none (no smart detect) |

Key facts that bound the design:

- **NVR-level `smartDetection`: `{enable: true, faceRecognition: true,
  licensePlateRecognition: true}`** — Protect is *already* running face recognition and
  LPR (there is a dedicated `smart_detect_face` postgres DB on the console). The two AI
  Pros produce face + plate detections; richer metadata than framing (1) assumed.
- **RTSP(S) is DISABLED on every channel of every camera** (`isRtspEnabled: false`
  across all 39 channels; each camera has High/Medium/Low). Any frame/clip pipeline
  needs either per-camera RTSP enablement (Protect UI change — operator) or snapshot
  pulls via the integration API.
- **Retention is keep-until-full, ~24 days**: no `recordingRetentionDurationMs` set,
  `autoRetentionEnabled: false`; UNVR volume is **15 TB at 97% used** with
  ~557 GB/day HQ + ~34 GB/day LQ (≈0.59 TB/day) → ≈24 days of depth. Framing (4)
  ("last Tuesday" queries) is bounded by this window unless events/frames are archived
  elsewhere.
- **Event volume is modest** (last 7 days): motion 1 355 (~190/day), smartDetectZone
  543, smartDetectLine 65, smartAudioDetect 47, loiter 5 → **~94 smart events/day,
  ~280 events/day total**. At this rate an event-level (not frame-level) pipeline is
  nowhere near Loki's danger zone, and LLM-per-event costs are small.
- Protect also keeps `transcriptions`, `detections`, `smartDetectTracks`, heatmaps and
  per-event `thumbnails`/`packageThumbnails` tables — there is more queryable signal
  on-box than the webhook payloads expose. `aiFeatureSettings` is empty and
  `isAiReportingEnabled: false` (no UniFi cloud AI reporting).

### Compute for inference
- **`k8s-gpu1`** — **Tesla P40, 24 GB VRAM**, `nvidia.com/gpu.replicas = 2`
  (time-sliced, so `nvidia.com/gpu.shared: 2`), node has 8 vCPU / ~12 GB RAM.
- **Ollama** runs there (`ollama` ns) with **text-only** models loaded:
  `qwen2.5:14b` (9 GB) and `qwen2.5:32b` (19 GB). **No vision model is present.**
- ✅ **RESOLVED 2026-08-14: the Pascal/CUDA-13 fear does not block us.** Verified live:
  `qwen2.5:14b` runs **100% GPU** on the P40 under ollama **0.32.13** with driver
  **580.105.08**. The node's "CUDA runtime 13.0" label is just the driver's max
  supported API version; ollama bundles its own CUDA-12 runner compiled for sm_61.
  Quantised GGUF vision models (qwen2.5-VL/llava class) are expected to run the same
  way. ⚠️ Residual risk: **driver 580.x is NVIDIA's final Pascal branch** — the
  platform is frozen. If ollama ever drops its CUDA-12 runner, gpu1 stops upgrading
  (pin the ollama version at that point). Pascal's weak FP16 still means GGUF
  quantised via ollama, not FP16 transformers.
- Node RAM (12 GB) is *smaller* than the 32b model — that model lives in VRAM. Adding a
  vision model concurrently needs a VRAM budget, not just disk.

### GPU power / cost analysis (measured 2026-08-14, DCGM + nvidia-smi)

Measured on the P40 (driver 580.105.08, ollama 0.32.13, qwen2.5:14b Q4):

| State | Draw | Notes |
|---|---|---|
| Idle, no model in VRAM | **~10 W** | 30-day Prometheus average is 10.9 W — the GPU is essentially always in this state today |
| **Model resident in VRAM, idle** | **~54 W** | ⚠️ The P40 does NOT downclock while VRAM is allocated (stays at 1303 MHz). This is the dominant cost of a near-real-time design |
| Generating | ~191 W @ 99% util | ~26 tok/s generation, ~490 tok/s prefill on qwen2.5:14b |

Cost model at an assumed **$0.30/kWh** (scale linearly for the actual tariff):

- **Inference bursts are negligible.** ~150 LLM calls/day × ~6 s ≈ 15 GPU-minutes/day
  ≈ **~$0.5–1/month** marginal. Per-event vision snapshots (~94/day × ~3 s) add cents.
- **The resident-model penalty is the real number.** Keeping a model loaded 24/7 for
  "someone at the gate now" latency = +44 W continuous ≈ 32 kWh/mo ≈ **~$10/month**.
  On-demand loading instead costs ~nothing but adds ~5–15 s model-load latency per
  cold event. ⏳ Worth a spike: locking low idle clocks (`nvidia-smi -lgc`) while
  resident may cut the 54 W substantially — unverified.
- **A newer GPU is NOT justified on power.** Modern cards idle ~10–20 W with VRAM
  allocated, saving ~$8–9/month over a resident P40 — a 4–5-year payback on even a
  ~$450 card. A new GPU is a capability decision (bigger/faster models, proper
  CUDA-13-era support, NVENC for frame pipelines), not a power saving.
- **Hosted comparison (Claude Haiku 4.5, $1/$5 per MTok — cheapest current Anthropic
  model):** text-only event alerting ≈ $3–10/month depending on batching + prompt
  caching; adding one vision snapshot per smart event ≈ +$6–8/month. So hosted-text
  ≈ local-resident in cost; hosted-vision means household images to a third party,
  which the operator gated on being very cheap. Anthropic models don't take audio —
  STT is local (whisper on P40 or even CPU) or a separate hosted STT service either way.

**Net:** the GPU is sunk hardware and the workload is light; local inference costs
~$1/mo (on-demand) to ~$11/mo (always-resident) in electricity. The design choice is
latency-vs-residency, not local-vs-hosted on cost grounds.

### Existing alerting / LLM plumbing to reuse (do NOT rebuild)
- **`ai-advisor`** — already does LLM analysis of alerts and emails via SES + IRSA.
  Dashboard: `platform/kubernetes/monitoring/dashboards/ai-advisor.yaml`. **This is the
  most likely integration point for framing (1).**
- **ntfy** (`platform/kubernetes/ntfy/`) — self-hosted push to phone over Tailscale;
  second critical-alert channel. Good fit for camera pushes.
- **Home Assistant** (`home-automation` ns) — receives the Protect webhooks today.
  ⚠️ **HA automations are UI-managed** in `/config/automations.yaml` inside the PVC,
  **not in git**. Anything built there is invisible to GitOps and won't survive a
  rebuild — factor that in or deliberately choose a different home.
- **Loki / Prometheus / Alertmanager** — the alerting spine.

---

## 3. Constraints that will bite (learned the hard way here)

- **Loki has limited headroom.** Apiserver audit once hit ~14 GB/day and filled the Loki
  PVC to 99%. Tetragon's export is deliberately allowlist-limited for the same reason.
  **A per-frame or per-event log firehose from cameras will break Loki** — budget the
  ingest rate before choosing it as the event store.
- **Cilium NetworkPolicy tiers are ENFORCING** on 14 namespaces including
  `home-automation`, `monitoring` and `plex`. Any new workload in an enforced namespace,
  or reaching into one, needs its tier allowlist updated in the same change or traffic
  is **silently dropped**. And allowlists must permit the **container/target port**, not
  the Service port. See `docs/runbooks/networkpolicy-tiers.md`.
- **Kyverno enforces** — no `:latest`, no untagged images; CPU/memory requests required
  (a mutate injects a small default).
- **Alert fatigue is a real, previously-experienced failure mode here** (an overnight
  advisor/status email storm needed its own remediation session). A camera pipeline is a
  *high-volume* event source pointed at a notification system. **Design suppression,
  dedup and rate-limiting up front, not after the first noisy night.**
- **Privacy/retention is a genuine design input**, not a footnote: continuous footage
  analysis means video or frames leave the NVR. If any hosted model is considered, that
  is household video going to a third party — decide deliberately. Local-only inference
  on gpu1 avoids this entirely and is the reason the GPU question above matters.

---

### Webhook path + payload (traced 2026-08-14)

- **Protect Alarm Manager has 41 live automations** (queried from the `automations`
  table). 8 are `HTTP_REQUEST` actions and **all point at the 5 HA webhook IDs** via the
  working IP-literal path (`http://10.10.201.70:8088/api/webhook/<id>`) — the
  outstanding "confirm all Alarm Manager URLs switched" item is effectively verified.
  The other 34 actions are `SEND_NOTIFICATION` (Protect app push).
- **The 5 HA webhook automations are night-only motion-light triggers and DISCARD the
  payload** (no `trigger.json` references in `/config/automations.yaml`). Nothing
  consumes the event content today.
- **The fired-trigger payload is rich** (verified from `automationsHistory.data`, which
  records exactly what a webhook body's `alarm.triggers[]` carries). A real
  "Access Road Entry" firing contained: `key: line_crossed`, device MAC, eventId,
  timestamps, `sourceEvent` with `type: smartDetectLine`, **confidence score**,
  **`smartDetectTypes: ["licensePlate","vehicle"]`**, per-line directional counts
  (`persons/vehicles A2B vs B2A`), line status `enter`, the line's configured
  direction/objectTypes, and **weather at event time**. Motion events are leaner
  (no smart types, score 0).
- **Directional "entering the private road" filtering already exists**: the
  "Access Road Entry" line (direction `BA`) on the AI Pro and "Gate Entry" on Gate are
  line-crossing automations that fire only on entry — precisely the operator's
  street-traffic-vs-entry distinction, computed camera-side. Loitering automations
  cover Access Rd/Gate/Driveway Lower/Intercom.
- **Protect's `transcriptions` table is EMPTY** and `aiFeatureSettings` is `{}`, no AI
  Port is paired (`isPairedWithAiPort: false` everywhere) — Protect does **not**
  transcribe audio today; speech-to-text would be built by us (audio comes only via
  RTSP(S), which is currently disabled).
- Per-event **thumbnails** exist in the DB (`thumbnails`, `packageThumbnails`,
  `detectedThumbnails` in event metadata) and via the integration API — a snapshot
  source for vision analysis that does not need RTSP.

## 4a. Operator direction (answered 2026-08-14)

The operator answered §4. Direction:

1. **Framing: start with (1) — smarter alerts from existing detections.** Many Protect
   notifications have been turned off because they were annoying; the want is *fewer,
   smarter alerts with more context*. Then layer on: **(3) cross-source correlation**
   with anything pullable from Home Assistant (e.g. security-system events), and
   **(4) natural-language history search**. **(2) vision model: only if very cheap or
   free** when hosted; local depends on the gpu1 verdict.
2. **Hosted inference is acceptable if very cheap or free** — not local-only dogma,
   but cost-gated.
3. **The failure being fixed:** too many meaningless alerts; the important ones drown.
   Also: *"don't like having to watch video / listen through voices"* — wants **text
   summaries first**, including of speech.
4. **All cameras matter; Access Road + Gate are the most active.** On Access Road,
   normal street traffic is noise — **traffic entering the private road** is the
   signal. (A directional/zone distinction — smartDetectLine/zone data may already
   encode this.)
5. **Latency: as close to real-time as possible** for "someone at the gate now".
6. **NEW ask (not in the original framings): investigate near-real-time speech-to-text
   on camera audio**, feeding both alerts and history. (Checked: Protect's
   `transcriptions` table is empty — no built-in transcription without AI Port
   hardware; we'd build STT ourselves, which requires enabling RTSP(S) for audio.)
7. **NEW ask (2026-08-14, mid-session): an AI/LLM manager for Home Assistant** —
   dynamic control (e.g. lighting) replacing the fairly static pre-programmed
   automations. Separate deliverable from camera alerting, but shares the LLM
   plumbing and the HA integration surface; scope it alongside framing (3).

## 4. Open questions for the operator (superseded — see §4a)

1. **Which framing (1–4 in §1) is the actual want?** Biggest single decision.
2. **Local-only inference, or is a hosted vision API acceptable?** Drives everything.
3. **What's the failure you're trying to fix** — too many notifications, missed events,
   or no way to search history? The answer selects the design.
4. **Which cameras matter?** All, or specific approaches (gate, doors)?
5. **Latency expectation** — near-real-time ("someone is at the gate now") or
   retrospective digest ("here's what happened overnight")? Real-time on a P40 with a
   quantised vision model is a meaningfully harder build.

---

## 5. Suggested first steps for whoever picks this up

1. ✅ **Enumerate the cameras** — done 2026-08-14, see the inventory in §2 (done via
   SSH + Protect DB since the `protect-tf` key turned out not to be in SOPS).
2. ✅ **Pascal/CUDA-13 confirmed viable 2026-08-14** (see §2 compute) — GPU inference
   works under ollama's bundled CUDA-12 runner; driver 580 = final Pascal branch.
   ✅ **Vision spike PASSED (2026-08-14, operator-approved pull):** `qwen2.5vl:7b`
   (6.0 GB disk, 5.9 GB VRAM) runs **100% GPU** on the P40. On a real event
   thumbnail (640×360) it produced an accurate, alert-grade description ("a man
   walking down a driveway… green shirt, dark pants, moving away from the camera
   towards a parked car") and even OCR'd the OSD overlay (camera name + timestamp).
   Timings: **cold ≈ 24 s** (18 s model load + inference), **warm ≈ 5–6 s** per
   snapshot (image prefill ~1.1K tokens @ 337 tok/s, generation 47 tok/s). Local
   vision for framing (2) is confirmed viable — no hosted API needed.
3. ✅ **Webhook path traced 2026-08-14** (see §2 webhook findings) — payload is rich
   (directional line-crossing, smart types, scores); HA currently discards it.
4. Only then design. Prefer extending `ai-advisor` over a new service if the answer is
   framing (1). **→ Next step as of 2026-08-14: write the design doc** for the layered
   build in §4a (alerts → correlation → history → STT/vision), with a costed
   hosted-vs-local comparison for the vision/STT pieces.

## 6. Reading list

- `CLAUDE.md` §5 — Protect webhook bug, HA automation caveat, netpol tiers, Loki limits
- `docs/runbooks/networkpolicy-tiers.md` — the operational tax on any new workload
- `platform/kubernetes/home-automation/ingressroute-webhook.yaml` — the live event path
- `platform/kubernetes/monitoring/dashboards/ai-advisor.yaml` — existing LLM pipeline
- `docs/planning/outstanding-work.md` + `session-log.md` — current frontier
