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
- **ServiceAccount** `cue-api` (`00-serviceaccount.yaml`) — the IRSA subject; the
  pod runs as this SA so its projected web-identity token can assume the AWS role
  (see Config / secrets).
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
  (the CF Access service token for `/ingest/healthkit`), `CUE_GOOGLE_PLACES_KEY` (Places API
  (New) key for **Find-food**, provisioned by `infra/terraform/google/`; the feature is **live** —
  `CUE_FIND_FOOD: 'true'` is set inline in `01-deployment.yaml`). Add/update a value with, e.g.:
    ```bash
    sops set platform/kubernetes/cue-api/03-secret-app.sops.yaml \
      '["stringData"]["ANTHROPIC_API_KEY"]' '"sk-ant-..."'
    ```
- `ghcr-cue` Secret (`04-secret-ghcr.sops.yaml`, SOPS) — ghcr read-only pull
  cred. Created from a `read:packages` PAT.
- **AWS / S3 media (M75 IRSA, no static keys).** The pod runs as the `cue-api` SA
  (`00-serviceaccount.yaml`) and assumes the **`wind-irsa-cue-media`** IAM role
  (`arn:aws:iam::830881980142:role/wind-irsa-cue-media`, trust locked to
  `system:serviceaccount:cue:cue-api` in `infra/terraform/aws/cluster-irsa`) for
  the Cue media S3 bucket (`CUE_MEDIA_BUCKET`). The AWS SDK auto-assumes it from
  `AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE` / `AWS_REGION` using a projected
  SA token (aud `sts.amazonaws.com`) — short-lived creds only, no static keys on
  the pod.

## Public access — cloudflared tunnel + CF Access (per-path)
`cue.etherport.net` is served by the wind-cluster cloudflared tunnel
(`infra/terraform/cloudflare/main.tf`), which now passes the **whole app** to the
origin; **Cloudflare Access gates per path** (`infra/terraform/cloudflare/cue-access.tf`):
- `/health` → **service token** (`cue-health-probe`; the blackbox-exporter probe
  sends the `CF-Access-Client-*` headers — the old public bypass+everyone policy
  was replaced 2026-07-03, so `/health` is no longer anonymous)
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
