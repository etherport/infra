# backup-approval — delete-approval service (Cloudflare Access)

Small in-cluster web service that lets the operator approve large S3 backup
deletions from an email button, instead of hand-editing env on the sync job.
It is the human-in-the-loop half of the aws-s3 sync's **delete guard** — see
[`../aws-s3/README.md` → Approval flow](../aws-s3/README.md#approval-flow-cloudflare-access-button)
for the full design.

## What it is
- **Deployment + Service `backup-approval`** (this dir), reusing the
  `ghcr.io/sparked-diamond/aws-s3-sync` image and running
  `approval-server.py` (in that image's `scripts/`). Pure stdlib HTTP; S3 via
  the bundled aws-cli.
- Exposed at **`backup-approve.wind.etherport.net`** via the Cloudflare tunnel,
  behind **Cloudflare Access** (operator email only). The tunnel ingress + DNS +
  Access app are one `cf_tunnel_services` entry in `infra/terraform/cloudflare`.
- **`approval-hmac`** secret (`01-hmac-secret.sops.yaml`) — the HMAC key shared
  with the sync job, which signs the approval tokens.

## Endpoints
- `GET /healthz` — liveness/readiness.
- `GET /approve?t=<token>` — verify token → render the pending deletion (rollup,
  sample, full-manifest CSV link) + a Confirm button.
- `GET /manifest?t=<token>` — stream the full delete manifest CSV.
- `POST /approve` — verify token → write the scoped one-time approval marker
  `approvals/approved/<share>.json`.

## Security model
1. **Cloudflare Access** (edge) restricts who can reach it.
2. **HMAC token** binds each request to a real pending deletion (share / run_id /
   would_delete) — unforgeable, can't be pointed at a larger deletion.
3. **GET renders, POST confirms** — two-step defeats email link-prefetch.
4. Optional `APPROVAL_REQUIRE_CF_EMAIL=true` (+ `APPROVAL_ALLOWED_EMAILS`) also
   rejects in-cluster direct hits that bypass the tunnel.

The service **cannot delete anything** — it only records consent that the next
guarded sync run checks (and consumes).
