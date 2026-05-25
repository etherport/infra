# Google Cloud Platform — partial IaC

## What this module covers

- The GCP project (`google_project`, imported from existing dashboard-created project)
- API enablements (`google_project_service` — IAM, IAM credentials, cloud resource manager)
- Future: service accounts + IAM bindings as those become needed

## What this module CAN'T cover (Google API limitations)

These are deliberately manual + documented in the runbook below:

- **OAuth consent screen** — App name, support email, scopes, test users, publish-to-production. Google's API doesn't expose programmatic creation of consent screen configuration on non-Enterprise accounts.
- **OAuth 2.0 Client IDs** — The Client ID + Client Secret pair that Cloudflare Zero Trust uses for Google SSO IdP. `google_iap_client` only works for IAP-protected GCP-internal resources, not for third-party OIDC integrations.

These are one-time setup; once done they don't change. The runbook captures the exact procedure so any future re-setup is deterministic.

## Setup runbook (one-time, ~5 min)

Already done 2026-05-25 for the existing Cloudflare Zero Trust IdP. Recapped here for replay-ability.

### 1. Create project in console
[console.cloud.google.com](https://console.cloud.google.com) → project dropdown → New Project
- Name: `cloudflare-zero-trust`
- No organization
- Create + switch to it

### 2. Configure OAuth consent screen
Sidebar → APIs & Services → OAuth consent screen
- User type: **External** (personal Gmail)
- App name: `Cloudflare Access — Etherport`
- User support email: `grahamsm@gmail.com`
- Developer contact: same
- **Scopes**: skip (defaults — email, profile, openid — are what CF needs)
- **Test users**: add `grahamsm@gmail.com` so you can log in while app is in "Testing" mode (Production publish requires Google review for non-default scope sets; not needed for our use)
- Save

### 3. Create OAuth 2.0 Client ID
Sidebar → APIs & Services → Credentials → + Create credentials → OAuth client ID
- Application type: **Web application**
- Name: `Cloudflare Zero Trust`
- **Authorized JavaScript origins**: `https://<cf-team>.cloudflareaccess.com`
- **Authorized redirect URIs**: `https://<cf-team>.cloudflareaccess.com/cdn-cgi/access/callback`
- Create → save Client ID + Secret

### 4. Save credentials
- 1P item: `Cloudflare Zero Trust Google IdP`
  - `client_id` (Concealed)
  - `client_secret` (Concealed)
  - Notes: project name + CF team URL
- Paste both into Cloudflare Zero Trust → Settings → Authentication → Add Google IdP

### 5. Import the project into TF state

```bash
cd infra/terraform/google
terraform init

# Find the project ID (from console URL: dashboard?project=<project-id>)
PROJECT_ID="<from console>"

TF_VAR_gcp_project_id=$PROJECT_ID \
  terraform import google_project.cloudflare_zero_trust $PROJECT_ID
```

After import, `terraform plan` should show zero changes if the project state matches the TF resource declaration.

## Apply

```bash
TF_VAR_gcp_project_id=$PROJECT_ID terraform plan
TF_VAR_gcp_project_id=$PROJECT_ID terraform apply
```

## Rotation

To rotate the OAuth Client Secret:
1. console → Credentials → click your "Cloudflare Zero Trust" client → "Reset secret"
2. Copy new secret → update 1P item
3. Paste into Cloudflare Zero Trust → Settings → Authentication → Google → Edit → Client secret
4. SSO continues working (CF caches the secret in memory; takes effect immediately on next login)

## Future scope (when needed)

- Service accounts for any GCP-resident tooling (none today)
- google_storage_bucket if we ever move backups off S3 to GCS (not planned)
- google_dns_managed_zone if we ever delegate a subdomain to GCP (not planned)
