# L21 — GCP Terraform auth → Workload Identity Federation (no static key)

**Status:** ✅ DONE 2026-06-13. `infra/terraform/google` is now live via
GitHub→GCP Workload Identity Federation — NO static key (mirrors H29). CI
dispatch plan = "No changes. Your infrastructure matches the configuration."

**What it took (beyond the bootstrap below):**
- Set the `GCP_PROJECT_ID` repo secret (`homelab-infra-497414`) — it was empty,
  separate from the never-set `GCP_SA_KEY`.
- Enabled `iamcredentials.googleapis.com` (required for WIF token exchange) +
  `cloudresourcemanager.googleapis.com` + `cloudbilling.googleapis.com` on the
  host project.
- Imported `google_project.cloudflare_zero_trust`, `google_project.home_assistant_nest`,
  and the 2 `google_project_service.ha_nest[*]` (locally, via owner ADC).
- Declared `billing_account = "0169E4-61F6AE-AFE6C8"` on the CF-SSO project to
  stop import drift wanting to detach billing.
- `GCP_SA_KEY` was never actually a secret (404 on delete) — no cleanup needed.

Original plan retained below for the record.

---

## Background

`infra/terraform/google` codifies 2 OAuth-only GCP projects (no billable
resources): `homelab-infra-497414` (CF Zero Trust Google-SSO IdP; project
number **909531984469**) and `poised-lens-448222-d2` (HA↔Nest SDM). The
`terraform-google` workflow has failed since inception on an **empty
`GCP_SA_KEY`** secret — confirmed **no state exists** (`s3://terraform.wind.etherport.net/google/` is absent), i.e. the module was never applied. This is the lone red CI check (also the only failure on the H30 SHA-pin PR #62).

## Target design (mirrors H29 for AWS)

GitHub Actions mints an OIDC token → GCP WIF exchanges it for short-lived SA
credentials. Trust scoped to `repo:sparked-diamond/infra`. No key to store/rotate.

## Step 1 — BOOTSTRAP (you, gcloud as a GCP admin)

The mini has no GCP creds, so these run from a machine where you're
authenticated (`gcloud auth login`). Pool lives in `homelab-infra-497414`.

```bash
PROJECT=homelab-infra-497414
PROJECT_NUM=909531984469
REPO=sparked-diamond/infra
gcloud config set project "$PROJECT"

# 1. Service account CI will impersonate.
gcloud iam service-accounts create gh-actions-terraform \
  --display-name="GitHub Actions Terraform (WIF)"
SA="gh-actions-terraform@${PROJECT}.iam.gserviceaccount.com"

# 2. Roles the module needs (project get/update + API enablement) on BOTH projects.
for P in homelab-infra-497414 poised-lens-448222-d2; do
  gcloud projects add-iam-policy-binding "$P" \
    --member="serviceAccount:${SA}" --role="roles/serviceusage.serviceUsageAdmin"
  gcloud projects add-iam-policy-binding "$P" \
    --member="serviceAccount:${SA}" --role="roles/resourcemanager.projectIamAdmin"
done
# Importing/refreshing google_project needs read on the project too:
gcloud organizations add-iam-policy-binding "$(gcloud projects describe $PROJECT --format='value(parent.id)')" \
  --member="serviceAccount:${SA}" --role="roles/browser" 2>/dev/null || true

# 3. Workload Identity Pool + GitHub OIDC provider.
gcloud iam workload-identity-pools create github \
  --location=global --display-name="GitHub Actions"
gcloud iam workload-identity-pools providers create-oidc github \
  --location=global --workload-identity-pool=github \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${REPO}'"

# 4. Let the repo's WIF identity impersonate the SA.
gcloud iam service-accounts add-iam-policy-binding "$SA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"

# 5. Print the two values to hand back:
echo "SA_EMAIL=$SA"
echo "WIF_PROVIDER=projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github/providers/github"
```

**Paste `SA_EMAIL` + `WIF_PROVIDER` back** and the agent wires step 2.

## Step 2 — wire the workflow (agent, after bootstrap)

Replace the `Auth to GCP` (GCP_SA_KEY) step in `.github/workflows/terraform-google.yml` with:

```yaml
      - name: Auth to GCP (WIF)
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: <WIF_PROVIDER>
          service_account: <SA_EMAIL>
```

`id-token: write` is already present. Drop the `GCP_SA_KEY` secret reference
entirely. The self-hosted `lifecycle` runner already has `gcloud`/SDK or the
action installs it.

## Step 3 — import the 2 projects (agent, once auth works)

The module has `prevent_destroy` on both projects, so import (never create):

```bash
cd infra/terraform/google
terraform init
terraform import google_project.cloudflare_zero_trust homelab-infra-497414
terraform import google_project.home_assistant_nest   poised-lens-448222-d2
terraform import 'google_project_service.ha_nest["smartdevicemanagement.googleapis.com"]' poised-lens-448222-d2/smartdevicemanagement.googleapis.com
terraform import 'google_project_service.ha_nest["pubsub.googleapis.com"]'                 poised-lens-448222-d2/pubsub.googleapis.com
terraform plan   # expect ~0 changes; reconcile any name/attr drift
```

Then CI plans green and the GCP estate is live, drift-detected IaC with no
static key. Remove the `GCP_SA_KEY` repo secret if it was ever set.

## Why not the alternatives
- **Static `GCP_SA_KEY`**: quickest but a long-lived cloud key — against the
  H29 grain we just established.
- **Delete the module**: viable (README already documents the projects), but you
  chose to keep it live; WIF gets that without the key.
