# Authentik — Homelab SSO IdP

Authentik (goauthentik **2026.5.3**) is the single sign-on identity provider for
the `wind` homelab (H38). It killed the old "internal == trusted" assumption:
internal apps now sit behind real auth instead of being reachable by anyone on
the LAN.

**Deployment Method**: Managed via **Flux GitOps**. Config changes ship from git.

## Overview

- **Portal / outpost**: `https://auth.wind.etherport.net` (internal only — via
  Technitium → Traefik VIP). The **embedded outpost** also serves the
  `/outpost.goauthentik.io/` forward-auth endpoints used by gated apps.
- **Database**: shared **HA Postgres** (CloudNativePG, `postgres` namespace) —
  Authentik has its own DB on the shared cluster, not a dedicated instance.
- **No Redis**: 2026.x dropped the Redis dependency (cache/task queue moved to
  Postgres); the old in-namespace Redis Deployment was removed entirely.
- **Components**: `server` + `worker` deployments; the **worker** is what
  applies blueprints. Both carry a **startupProbe** (60×10s, H44) so long DB
  migrations at upgrade time aren't killed mid-run by the liveness probe.

## What it gates

- **OIDC apps**: Grafana, Wiki.js, Open WebUI (`chat.wind.etherport.net`).
- **Forward-auth (domain-level)**: the browser device-admin UIs — Proxmox / IPMI
  / PDU / UPS / Technitium DNS / Traefik dashboard — via the Traefik
  `authentik-forward-auth@authentik` middleware (`38-forward-auth-middleware.yaml`).
- **Left ungated by design**: Home Assistant + Plex (own auth; forward-auth
  breaks HA mobile/API/webhooks and external CF logins) and machine APIs
  (loki / pushgateway / **ollama** — UDM-firewall-scoped, not browser apps).

## Configuration (GitOps blueprints)

App/provider config lives as **Authentik blueprints** in `40-blueprints.yaml`
(a ConfigMap). The **worker auto-applies** them on start. Secrets are injected
with `!Env` (e.g. `client_secret: !Env AUTHENTIK_GRAFANA_CLIENT_SECRET`),
sourced from `30-authentik-secret.sops.yaml` / `31-env-configmap.yaml`. To add
an app: add its blueprint (OAuth2 provider + Application), wire the client
secret via `!Env`, commit, reconcile.

## Footguns (read before editing — full detail in CLAUDE.md §5)

1. **NEVER put `password:` in a user blueprint.** Authentik re-applies it on
   *every* apply (write-only, can't diff) and clobbers any UI-set password on
   each worker restart. Manage human passwords/passkeys in the UI (`akadmin`
   = break-glass account).
2. **Grafana `role_attribute_path`**: a literal `'GrafanaAdmin'` evaluates to
   EMPTY (go-ini strips the quotes) → roles reset to Viewer every login. We use
   `skip_org_role_sync: true` + a manual server-admin grant instead.
3. **Dark theme** = brand `attributes.settings.theme.base=dark` (set via brand
   attributes, not a UI toggle).
4. **Forward-auth is wrong for machine APIs and HA** — it breaks mobile/API/
   webhook clients. Keep those ungated (firewall-scoped) or on their own auth.
5. **`branding_logo`/`branding_favicon` reject `data:` URIs (2026.5+).** They're
   validated as filenames/paths — a data URI fails validation and makes the WHOLE
   `branding` blueprint error out (`status=error`), so logo, favicon **and**
   `theme.base=dark` silently don't apply. Serve the image as a real file (in the
   `authentik-custom-css` ConfigMap → mounted into `/web/dist/` → served at
   `/static/dist/`) and reference it by path. Data URIs worked in 2024.12; the H44
   upgrade broke them (fixed 2026-07-18). Check blueprint health:
   `kubectl -n authentik exec deploy/authentik-server -- ak shell -c "from authentik.blueprints.models import BlueprintInstance as B; print([(b.name,b.status) for b in B.objects.exclude(status='successful')])"`

## Files

| File | Purpose |
|------|---------|
| `00-namespace.yaml` | `authentik` namespace |
| `30-authentik-secret.sops.yaml` | SOPS-encrypted secrets (secret key, client secrets) |
| `31-env-configmap.yaml` | Non-secret env (Postgres host, etc.) |
| `39-pdb.yaml` | Server PDB (minAvailable 1 — M114 HA; media PVC removed same change, emptyDir now) |
| `33-server-deployment.yaml` | Authentik server |
| `34-worker-deployment.yaml` | Authentik worker (applies blueprints) |
| `35-server-service.yaml` | ClusterIP service |
| `36-ingressroute.yaml` | Traefik IngressRoute (`auth.wind.etherport.net`) |
| `37-custom-css-configmap.yaml` | Custom CSS branding |
| `38-forward-auth-middleware.yaml` | `authentik-forward-auth` Traefik middleware |
| `40-blueprints.yaml` | OIDC/app blueprints (auto-applied by the worker) |
| `kustomization.yaml` | Kustomize config for Flux |

## Related

- **CLAUDE.md §5** — full H38 footgun detail and rationale.
- `docs/planning/outstanding-work.md` (H38), `docs/planning/session-log.md`
  (2026-06-23) — the SSO rollout pass.
