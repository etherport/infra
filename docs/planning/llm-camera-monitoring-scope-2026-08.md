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
- ⚠️ **The P40 is Pascal (sm_61) and this is the key hardware risk.** The node reports
  CUDA runtime 13.0, and NVIDIA dropped Pascal support in CUDA 13 — **verify before
  committing to a design**, because it determines whether newer vision-model runtimes
  and container images will run here at all. Pascal also has weak FP16, so quantised
  GGUF (Q4/Q8) via ollama is the realistic path rather than FP16 transformers.
- Node RAM (12 GB) is *smaller* than the 32b model — that model lives in VRAM. Adding a
  vision model concurrently needs a VRAM budget, not just disk.

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
   on camera audio**, feeding both alerts and history. Note: the Protect DB has a
   `transcriptions` table — check whether Protect already transcribes before building
   anything.

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
2. **Confirm the Pascal/CUDA-13 question** on gpu1 and test one quantised vision model
   (e.g. a llava/qwen-VL GGUF) under ollama. This is a ~1 hour spike that de-risks the
   whole project — if vision inference won't run on the P40, framings (2) and (3)
   need either new hardware or a hosted API.
3. **Trace one real Protect event end-to-end** through the existing webhook path to see
   exactly what payload arrives and what it already contains.
4. Only then design. Prefer extending `ai-advisor` over a new service if the answer is
   framing (1).

## 6. Reading list

- `CLAUDE.md` §5 — Protect webhook bug, HA automation caveat, netpol tiers, Loki limits
- `docs/runbooks/networkpolicy-tiers.md` — the operational tax on any new workload
- `platform/kubernetes/home-automation/ingressroute-webhook.yaml` — the live event path
- `platform/kubernetes/monitoring/dashboards/ai-advisor.yaml` — existing LLM pipeline
- `docs/planning/outstanding-work.md` + `session-log.md` — current frontier
