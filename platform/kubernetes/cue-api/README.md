# Cue API

Single-owner **dev** deployment of the Cue API (Node 24 + Fastify), in the
`cue` namespace alongside its Postgres (`cue-db`). Handles personal health data
and spends on an LLM key, so public exposure is deliberately minimal.

## Image
Built by GitHub Actions in the app repo (`sparked-diamond/cue`,
`.github/workflows/build-image.yml`) → **`ghcr.io/sparked-diamond/cue`** (private
package). The cluster pulls it via the `ghcr-cue` imagePullSecret. There is no
local Docker build — CI is the source of truth.

## Topology
- **Deployment** `cue-api` (1 replica). An **initContainer** runs
  `node dist/db/migrate.js` (idempotent drizzle migrations) before the app
  serves. `terminationGracePeriodSeconds: 15` (app does graceful SIGTERM ≤10s).
  Probes hit `GET /health`.
- **Service** `cue-api` — **ClusterIP** :3000. Public ingress is via the
  cloudflared tunnel (below); a tailnet-only LoadBalancer (`cue-api-ts`,
  `05-tailscale-svc.yaml`) + HTTPS Ingress (`06-ingress.yaml`,
  `cue-api.<tailnet>.ts.net`) expose it on the tailnet for dev. No public
  LoadBalancer / cert-manager.

## Config / secrets
- `DATABASE_URL` ← `cue-db-app` secret, key `uri` (CNPG-generated, in-cluster rw).
- `CUE_INTERACTION_LEARNING=true` (plain env, dev).
- `cue-app` Secret (SOPS-encrypted, `03-secret-app.sops.yaml`) — wired via an
  **optional** `envFrom` so the pod is healthy before it's fully populated. Keys:
  `ANTHROPIC_API_KEY`, `CUE_WEB_TOKEN_SECRET`, `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY`
  / `VAPID_SUBJECT` (Web Push), `CUE_HEALTHKIT_CF_CLIENT_ID` / `CUE_HEALTHKIT_CF_CLIENT_SECRET`
  (the CF Access service token for `/ingest/healthkit`). Add/update a value with, e.g.:
    ```bash
    sops set platform/kubernetes/cue-api/03-secret-app.sops.yaml \
      '["stringData"]["ANTHROPIC_API_KEY"]' '"sk-ant-..."'
    ```
- `ghcr-cue` Secret (`04-secret-ghcr.sops.yaml`, SOPS) — ghcr read-only pull
  cred. Created from a `read:packages` PAT.

## Public access — cloudflared tunnel + CF Access (per-path)
`cue.etherport.net` is served by the wind-cluster cloudflared tunnel
(`infra/terraform/cloudflare/main.tf`), which now passes the **whole app** to the
origin; **Cloudflare Access gates per path** (`infra/terraform/cloudflare/cue-access.tf`):
- `/health` → **bypass** (public liveness, no login)
- `/ingest/healthkit` → **service token** (the Apple Health Auto Export client; `CF-Access-Client-*`)
- everything else → **Google SSO**, allow-list = `var.cue_tester_emails`

The app additionally verifies the injected `Cf-Access-Jwt-Assertion` JWT
(`CUE_CF_ACCESS_*`) and maps the email → Cue user. **Telegram is retired**, so the old
`/health + /telegram/webhook` path-restriction is gone.

All other routes (`/coach/*`, `/meals/*`, `/onboarding`, `/progress/*`,
`/digestion/*`) are reachable only **in-cluster / over Tailscale** (the Service
is ClusterIP).

## Wiring
Deployed by Flux via `- ../../platform/kubernetes/cue-api` in
`clusters/wind/kustomization.yaml`. The image is digest-pinned + auto-bumped by
Flux image automation (`clusters/wind/image-automation/cue.yaml`); force a
redeploy with `kubectl rollout restart deploy/cue-api -n cue`.
