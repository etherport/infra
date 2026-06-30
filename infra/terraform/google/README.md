# Google Cloud Platform — partial IaC + replication runbooks

The homelab's entire GCP footprint after the 2026-06-03 audit: **two
credential/OAuth-only projects**, no billable compute/storage anywhere
(GCP spend ≈ $0). This module codifies the projects + API enablements;
the OAuth clients/consent screens they hold are **not** Terraform-manageable
(Google's API doesn't expose them) and are documented as replication
runbooks below.

| Project | ID | Holds | Billing |
|---|---|---|---|
| Cloudflare Zero Trust SSO | `homelab-infra-497414` | OAuth client for CF Access Google IdP | enabled |
| Home Assistant · Nest (SDM) | `poised-lens-448222-d2` | OAuth client + Device Access link for Nest | **disabled** (free tier) |

> Deleted in the 2026-06-03 cleanup (recoverable until ~2026-07-03 via
> `gcloud projects undelete`): `nas-access-457504` (dead TrueNAS-sync
> leftover), `youtube-api-keys-410001` (unused key, 0 traffic/90d),
> `extended-ripple-463516-q7` (empty "My First Project").

## What Terraform manages here

- Both `google_project` resources (pre-created in console, **imported** into state; `prevent_destroy = true`)
- `google_project_service` for the two APIs Nest needs (`smartdevicemanagement`, `pubsub`)
- On the CF-SSO project (`homelab-infra-497414`): `google_project_service` for `apikeys.googleapis.com`
  + `places.googleapis.com`, and a restricted `google_apikeys_key.cue_places` for the Cue **Find-food**
  feature (Places API New, server-side nearby search). See **Runbook C** below.

## What it CAN'T manage (Google API limitations)

These are deliberately manual + captured in the runbooks below so any
re-setup is deterministic:

- **OAuth consent screens** — app name, support email, scopes, test users, publish flow
- **OAuth 2.0 Client IDs** — the Client ID + Secret pairs (CF Access IdP; Nest). `google_iap_client` only covers IAP-internal resources, not third-party OIDC/SDM.
- **Nest Device Access Console project** — registered at console.nest.google ($5 one-time, paid), entirely separate from Cloud Console.

Client **IDs** are recorded below (they're not secret — they appear in
redirect flows). Client **secrets** live only in 1Password + the
consuming service (Cloudflare / Home Assistant), never in git.

---

## Verified config (2026-06-03)

- **CF SSO** — OAuth client `909531984469-evt1p0dn5h3v1op7vllntc5b5iob1k7q.apps.googleusercontent.com` (the `909531984469` prefix == this project's number, confirming it belongs here). No special API needed for OIDC. Functional proof: CF Access Google login works.
- **Nest** — `smartdevicemanagement.googleapis.com` (device control) + `pubsub.googleapis.com` (event stream) both enabled = exactly what HA Nest requires. Functional proof: Nest devices live in Home Assistant.

---

## Runbook A — Cloudflare Zero Trust Google SSO  (`homelab-infra-497414`)

Done 2026-05-25. Recapped for replay-ability.

### 1. Project
Console → New Project. (Current display name: `homelab-infra`. The TF
`name` matches it; change there to rename.)

### 2. OAuth consent screen
APIs & Services → OAuth consent screen
- User type: **External** (personal Gmail)
- App name: `Cloudflare Access — Etherport`; support + developer email: `grahamsm@gmail.com`
- Scopes: defaults (email, profile, openid) — what CF needs
- Test users: add `grahamsm@gmail.com` (keeps it in "Testing"; production publish not needed for default scopes)

### 3. OAuth 2.0 Client ID
APIs & Services → Credentials → Create credentials → OAuth client ID
- Type: **Web application**, name `Cloudflare Zero Trust`
- Authorized JS origins: `https://<cf-team>.cloudflareaccess.com`
- Authorized redirect URI: `https://<cf-team>.cloudflareaccess.com/cdn-cgi/access/callback`
- **Current Client ID**: `909531984469-evt1p0dn5h3v1op7vllntc5b5iob1k7q.apps.googleusercontent.com`

### 4. Wire + store
- 1Password item `Cloudflare Zero Trust Google IdP` (client_id in `username`, secret concealed)
- Paste both into Cloudflare Zero Trust → Settings → Authentication → Google IdP

### Rotation
Credentials → client → Reset secret → update 1P → paste into CF Access → takes effect next login.

---

## Runbook B — Home Assistant ↔ Nest (SDM)  (`poised-lens-448222-d2`)

Three linked pieces: the GCP project (OAuth client + APIs), the **Device
Access Console** project, and the HA integration. Replication order:

### 1. GCP project — enable APIs (Terraform-managed)
`smartdevicemanagement.googleapis.com` + `pubsub.googleapis.com` (this
module's `google_project_service.ha_nest`).

### 2. OAuth consent screen + Client ID
- Consent screen: External, add `grahamsm@gmail.com` as test user, add the
  SDM scope `https://www.googleapis.com/auth/sdm.service`.
- Credentials → OAuth client ID → **Web application**.
- Authorized redirect URI: `https://my.home-assistant.io/redirect/oauth`
  (HA "My" redirect) **and/or** `https://<ha-external-url>/auth/external/callback`.
- Record the Client ID here when replicating: `<nest-oauth-client-id>` (secret → 1P + HA).

### 3. Device Access Console  (console.nest.google/device-access)
- $5 one-time fee (already paid). Create/keep a project; note its
  **Device Access Project ID** (a UUID — this is HA's `project_id`).
- Link it to the OAuth Client ID from step 2.
- Enable Pub/Sub events.

### 4. Home Assistant
Settings → Devices & Services → Google Nest. Supply: OAuth `client_id` +
`client_secret`, the Device Access `project_id`, then complete the OAuth
consent flow. HA auto-creates the Pub/Sub subscription for events.

> **Note:** this project is intentionally **standalone** (not folded into
> `homelab-infra`). It costs $0, and migrating the OAuth client + Device
> Access link + re-authing HA would briefly break Nest for zero benefit.

## Runbook C — Cue Find-food: Places API (New) key  (`homelab-infra-497414`)

The Cue app's "Find food" feature calls **Places API (New)** server-side. Terraform
manages it on the CF-SSO project: enables `apikeys.googleapis.com` + `places.googleapis.com`
and creates a restricted key (`google_apikeys_key.cue_places`, API-restricted to
`places.googleapis.com` only — no referrer/IP restriction, since calls are server-side
from the cluster's dynamic-WAN egress).

> ⚠️ **Service id:** Places API (New) = **`places.googleapis.com`**.
> `places-backend.googleapis.com` is the **legacy** Places API — do not use it here. The
> key restriction must match the endpoint the app calls (`https://places.googleapis.com/v1/...`).

### 1. One-time IAM bootstrap (MANUAL — required before apply)
The WIF SA `gh-actions-terraform@homelab-infra-497414.iam.gserviceaccount.com` has
`serviceUsageAdmin` + `projectIamAdmin` + browser, but **no API-keys permission**, so a key
create fails until you grant it. Run once, from a `gcloud auth login` machine with project
admin (the devbox has no GCP creds), exactly as the SA was bootstrapped (L21):
```bash
gcloud projects add-iam-policy-binding homelab-infra-497414 \
  --member="serviceAccount:gh-actions-terraform@homelab-infra-497414.iam.gserviceaccount.com" \
  --role="roles/serviceusage.apiKeysAdmin"
```

### 2. Apply, then deliver the key to the app secret (out of band)
After `terraform-google.yml` (action=apply) succeeds:
```bash
KEY=$(terraform -chdir=infra/terraform/google output -raw cue_places_key)
sops set platform/kubernetes/cue-api/03-secret-app.sops.yaml \
  '["stringData"]["CUE_GOOGLE_PLACES_KEY"]' "\"$KEY\""
git add -A && git commit -m "feat(cue): Google Places API key for Find-food"
```
`envFrom: secretRef: cue-app` injects it into the pod (no Deployment edit). The feature stays
OFF until `CUE_FIND_FOOD: 'true'` is added to the cue-api Deployment env — done separately when
the cue side ships. (No automated TF→SOPS bridge by design — Flux owns the cluster.)

---

## Initial import (one-time)

```bash
cd infra/terraform/google
terraform init

# Project 1 — CF SSO (project ID from the GCP_PROJECT_ID CI secret)
TF_VAR_gcp_project_id=homelab-infra-497414 \
  terraform import google_project.cloudflare_zero_trust homelab-infra-497414

# Project 2 — HA Nest (hardcoded in main.tf)
TF_VAR_gcp_project_id=homelab-infra-497414 \
  terraform import google_project.home_assistant_nest poised-lens-448222-d2

# Nest's two API enablements
for api in smartdevicemanagement.googleapis.com pubsub.googleapis.com; do
  TF_VAR_gcp_project_id=homelab-infra-497414 \
    terraform import "google_project_service.ha_nest[\"$api\"]" "poised-lens-448222-d2/$api"
done
```

After import, `terraform plan` should show **zero changes** (sanity that
TF matches reality).

## Apply

```bash
TF_VAR_gcp_project_id=homelab-infra-497414 terraform plan
TF_VAR_gcp_project_id=homelab-infra-497414 terraform apply
```

## Future scope (when needed)

- Service accounts for GCP-resident tooling (none today; would add `iam`/`iamcredentials` APIs to the CF SSO project)
- `google_storage_bucket` if backups ever move from S3 to GCS (not planned)
