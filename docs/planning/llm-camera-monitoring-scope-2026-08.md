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
- **Not yet enumerated:** camera count, models, resolutions, whether they have on-device
  smart detections, current retention depth, and whether RTSP(S) streams are enabled.
  **Do this first** — it bounds every option below.

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

## 4. Open questions for the operator

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

1. **Enumerate the cameras** via the Protect read-only API — count, models, detection
   capabilities, retention. Everything else is guesswork until this exists.
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
