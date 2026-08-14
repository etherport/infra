# Design — LLM camera/security monitoring (M158)

**Status:** 📋 draft for operator review — nothing built. **Created:** 2026-08-14.
**Prereq reading:** [`llm-camera-monitoring-scope-2026-08.md`](llm-camera-monitoring-scope-2026-08.md)
(verified inventory, webhook payload trace, GPU verdict, power/cost analysis). This doc
turns the operator direction from that doc's §4a into a phased build plan.

## 0. Decisions carried in

- **Local inference on the P40** for text (and vision if the spike passes). Measured:
  the workload is ~15 GPU-minutes/day; cost is latency-vs-residency (~$1/mo on-demand
  vs ~$11/mo resident at $0.30/kWh), not local-vs-hosted. Hosted (Haiku 4.5) is the
  quality fallback, not the default. A **newer GPU stays on the table as a capability
  upgrade** (CUDA-13-era support, faster STT/vision, NVENC) — not as a power saving.
- Start with **smarter alerts** (framing 1), then **HA correlation** (3) and **NL
  history** (4); **STT** is a first-class goal; **vision** rides on the gpu1 spike.
- Alert-fatigue is the failure being fixed: suppression/dedup/rate-limiting are
  Phase-1 features, not afterthoughts.

## 1. Architecture (target)

```
UniFi Protect (Windprotect, VLAN 212)
  │ integration API (read-only, protect-tf key): WS event stream + snapshots
  │ RTSPS :7441 (Phase 3, after operator enables RTSP per camera)
  ▼
lookout (new ns, K8s)  ──── ollama (qwen2.5:14b; later qwen2.5-vl, whisper)
  │  event intake → enrich (thumbnail, HA context) → LLM triage → route
  ├── ntfy  (push: "someone at the gate" — near-real-time)
  ├── SES   (daily/overnight digest, ai-advisor pattern)
  └── postgres (shared CNPG): enriched events + summaries + transcripts
        ▲ NL history queries (LLM + SQL/full-text retrieval)
Home Assistant (enforced tier) — REST/WS pull of sensor/security events (Phase 2)
```

**New service `lookout`** (working name), own unlabeled namespace (allow-all netpol at
first; tier later per the standard audit flow). One small deployment; Kyverno-clean
(pinned digest, resource requests). Not built on ai-advisor: the alerts-vs-advisor
cadence, the WS ingestion loop, and later STT make it a poor fit, but it **reuses**
ai-advisor's SES/IRSA pattern for digests and ntfy for push.

**Event intake:** subscribe to the Protect **integration API WebSocket** (all events,
richer than webhooks, no Alarm-Manager UI churn; the webhook path stays as-is for the
motion-lights). Requires the `protect-tf` key in the SOPS bundle (operator action A2).
Fallback if the WS proves unreliable: operator adds Alarm-Manager webhook actions
pointing at the existing `:8088` entrypoint with a new path routed to lookout.

**Event store: postgres, NOT Loki.** ~280 events/day of JSON+text is trivial; Loki's
headroom stays untouched. Crossing into the enforced `postgres` tier means updating
`platform/kubernetes/networkpolicies/1x-tier-postgres.yaml` in the same change
(container port 5432) — the documented tier tax.

**LLM calls:** ollama HTTP in-cluster (`ollama` ns is unlabeled → no netpol tax).
Start with **on-demand model loading** (~5–15 s added latency on a cold event,
~$1/mo). If gate-alert latency annoys in practice, either pin the model resident
(`keep_alive: -1`, ~$10/mo) or first spike `nvidia-smi -lgc` low-clock locking to
shrink the 54 W resident-idle penalty.

## 2. Phase 1 — smarter alerts (framing 1)

Pipeline per event batch (rolling ~2-min window, flushed early for high-priority):

1. **Rule pre-filter (no LLM):** drop/deprioritize by camera+type policy. Access Road:
   `line_crossed` (direction=enter) and person events are signal; plain motion/street
   traffic is noise. Gate/doors: person, ring, loiter = high. Weather field ignored.
2. **LLM triage** (qwen2.5:14b, structured JSON out): given the batch + last N-minutes
   context from postgres, emit `{priority, headline, narrative, dedupe_key}` — e.g.
   "same vehicle seen at Access Road then Gate, 90s apart" instead of two alerts.
3. **Routing:** `critical/high` → ntfy push immediately (rate-limited per dedupe_key,
   e.g. max 1/10min); `medium` → hourly rollup; `low` → overnight digest email only.
   Quiet-hours profile. Everything lands in postgres regardless.
4. **Digest:** overnight + on-demand summary email (SES), ai-advisor style.

Acceptance: a week with strictly fewer pushes than Protect's own notifications while
catching 100% of person/entry events at Gate + Access Road (B2/B3: verify both the
positive and the suppression path).

## 3. Phase 2 — HA correlation + NL history

- **HA intake:** lookout subscribes to HA's WebSocket event bus (long-lived access
  token) for door/motion/security entities; correlation context for triage ("garage
  door opened 20 s after vehicle entered drive").
  ⚠️ `home-automation` is an **enforced** tier → add lookout→HA `:8123` (container
  port) to `1x-tier-home-automation.yaml` in the same change.
- **NL history:** CLI/chat endpoint (and later Open WebUI tool or HA conversation):
  LLM translates the question to SQL/full-text over the events table, answers with
  citations (event ids/timestamps). Text summaries are tiny → keep ≥1 year, far past
  the NVR's ~24-day footage window; answers can link `protect://` event paths while
  footage still exists.

## 4. Phase 3 — STT + vision

**STT (operator priority):**
- Source: **RTSPS from the NVR** (Protect rebroadcasts; we never touch cameras
  directly): `rtsps://10.10.212.10:7441/<alias>` once RTSP is enabled per camera (A1).
- Trigger: event-driven — on person/ring/loiter/talkback events, ffmpeg pulls ~60–90 s
  of **audio only** from the relevant camera stream; whisper (faster-whisper
  small/int8 — CPU-viable, GPU-fast; sm_61-compatible builds exist) transcribes;
  transcript attaches to the event → included in push/digest/history. This satisfies
  "read what was said instead of listening" without a 24/7 transcription firehose.
  Continuous STT on 1–2 cameras is a later opt-in (adds constant GPU/CPU load).
- Network: cluster pods must reach `10.10.212.10:7441` — expect the UDM **zone
  firewall to block Trusted→Cameras**; needs one rule in
  `infra/ansible/playbooks/udm-firewall.yml` (A3, approval before apply).

**Vision:** on high-priority events, feed the event snapshot/thumbnail (integration
API — no RTSP needed) to a local vision GGUF for a one-line description ("delivery
carrier holding package" vs "person trying door handle"). Gated on the pending gpu1
spike (A4). Hosted vision stays off unless local quality disappoints AND the operator
accepts frames leaving the network.

## 5. Sibling: HA LLM manager (lighting etc.)

Separate deliverable, shared plumbing. Recommended shape: **HA's native conversation/
LLM integration pointed at ollama** (HA 2024+ supports local LLM backends with tool
calling against HA services), so "dim the deck lights when the movie starts" style
control lives inside HA's permission model rather than a bespoke bridge. Scoping task:
verify the HA release in use supports local-LLM conversation agents + assist tools;
decide UI-managed vs git-managed config (same PVC caveat as automations). Not in
Phases 1–3; tracked under M158 until split out.

## 6. Operator actions (the "what you need to do" list)

- **A1 — enable RTSP for audio (Protect UI, per camera):** Protect web UI → Unifi
  Devices →
  select camera → Settings → Advanced → **RTSP** → enable ONE channel (Medium is
  plenty for audio). Start with: **Gate, Access Road, Driveway Gate - Entry
  (intercom), Front Door**. Note the shown stream alias per camera. This only
  *exposes* the stream on the NVR; nothing changes about recording.
- **A2 — put the `protect-tf` key into the SOPS bundle** (1Password → `homelab-ops.sops.yaml`
  on the mini/VNC, key name suggestion `protect_api_key`) — closes the long-open
  optional item; replaces the SSH+psql workaround with the proper read-only API.
- **A3 — (Phase 3, when asked) approve the UDM firewall rule** cluster→NVR :7441.
- **A4 — approve the vision spike:** pull `qwen2.5vl:7b` (~6 GB disk) on gpu1.
- **A5 — (optional, your fan hunch) check the BMC fan mode:** chassis fans have been
  pinned at 5800–6000 rpm for 30 days with GPU at 28 °C — that's a fan *policy*
  (or a BMC floor for the passive GPU's presence), not thermal response. The whole
  hypervisor draws 126 W wall (~$27/mo at $0.30/kWh), so the rack isn't the $200
  bill either way; a Quiet/Optimal fan mode in the BMC UI is the lever if noise or
  fan wattage is the concern.

## 7. Build order / checkpoints

1. Phase-1 skeleton behind a single feature flag; verify WS intake against live
   events (read-only) before any notification is sent.
2. Alerts to a **test ntfy topic** first; operator flips to the real topic after a
   quiet-night soak. Suppression validated per §2 acceptance.
3. Phase 2 tier-allowlist changes ship with the code that needs them (netpol tax).
4. Phase 3 after A1+A3; whisper spike is CPU-first (zero approvals), GPU after.
```
