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
- **Service** `cue-api` — **ClusterIP** :3000. No LoadBalancer / Ingress /
  cert-manager.

## Config / secrets
- `DATABASE_URL` ← `cue-db-app` secret, key `uri` (CNPG-generated, in-cluster rw).
- `CUE_INTERACTION_LEARNING=true` (plain env, dev).
- `cue-app` Secret (SOPS-encrypted, `03-secret-app.sops.yaml`) — wired via an
  **optional** `envFrom` so the pod is healthy before it's fully populated:
  - `TELEGRAM_WEBHOOK_SECRET` — set (generated at create time).
  - `TELEGRAM_USER_ID` — set (`00000000-0000-4000-8000-000000000001`, seed owner).
  - `ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_CHAT_IDS` —
    **to be added**. Add with, e.g.:
    ```bash
    sops --set '["stringData"]["ANTHROPIC_API_KEY"] "sk-ant-..."' \
      platform/kubernetes/cue-api/03-secret-app.sops.yaml
    ```
- `ghcr-cue` Secret (`04-secret-ghcr.sops.yaml`, SOPS) — ghcr read-only pull
  cred. Created from a `read:packages` PAT; currently commented out in
  `kustomization.yaml` until the PAT is provided.

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
Add `- ../../platform/kubernetes/cue-api` to `clusters/wind/kustomization.yaml`
to have Flux deploy it (done once the image + `ghcr-cue` pull secret exist).
