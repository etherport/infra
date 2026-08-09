# Container image pinning + Renovate policy

What gets pinned how, who bumps it, and how to add a new image without
collapsing the policy.

## Why this matters

Two failure modes we want to avoid:

1. **`:latest` / `:main` floating tags in production manifests.** A pod
   restart at the wrong time pulls a new image we never tested. Rollback
   then means "find the previous digest from someone's terminal scrollback."
2. **Manual version bumps everywhere.** Every chart, every Deployment.
   Skipped bumps silently rot.

Goal: every image runs at a known version that's either deliberately
pinned or auto-bumped on a documented cadence with a reviewable PR.

## Three buckets

### Bucket A — Flux ImagePolicy / ImageUpdateAutomation

Managed by `clusters/wind/image-automation/`. The `flux-system`
controller scans the registry on an interval and rewrites the manifest
YAML in this repo when a new tag matches the policy.

**How to spot one:** `image: <ref> # {"$imagepolicy": "flux-system:<policy-name>"}`

**Currently managed:**

| Image                                    | Policy           | Pattern                                                |
|------------------------------------------|------------------|--------------------------------------------------------|
| `python:3.X-alpine`                      | `python-alpine`  | newest `3.<minor>-alpine`                              |
| `python:3.X-slim`                        | `python-slim`    | newest `3.<minor>-slim`                                |
| `busybox:1.X.Y`                          | `busybox`        | newest `1.<minor>.<patch>` (excludes latest/stable)    |
| `velero/velero-plugin-for-aws`           | `velero-plugin-aws` | semver `>=1.0.0`                                    |
| `cloudflare/cloudflared`                 | `cloudflared`    | per-app pattern in `clusters/wind/image-automation/`   |
| `blackbox-exporter`                      | `blackbox-exporter` | per-app pattern in `clusters/wind/image-automation/`|
| `ghcr.io/sparked-diamond/cue:latest`     | `cue-api`        | tracks moving `:latest`, reflects its digest (see below) |
| `home-assistant`, `ollama`, `open-webui`, `wikijs`, `plex`, `rclone`, `technitium` | per-app | per-app pattern in `clusters/wind/image-automation/` |

`cue` is the **one exception** to "`ghcr.io/etherport/* = Bucket C`":
it's an internally-built image but Flux-managed (Bucket A) because its
tags are unsortable `sha-<commit>` plus a moving `:latest`, so automation
tracks `:latest` and pins its reflected digest — see
`clusters/wind/image-automation/cue.yaml`.

**When to use:** the image is from a third party with semver-ish tags
and we want the latest patch automatically.

**Digest pinning (H30, done 2026-06-24):** every Flux-managed ImagePolicy
now sets `digestReflectionPolicy: Always`, so the manifest line Flux writes
is `tag@sha256:<digest>`, not just the tag. The selected tag still picks the
version; the appended digest makes the pull immutable (a re-pushed tag can't
silently change the running image, and rollback has the exact digest in git).
Example of what Flux writes:
`image: rclone/rclone:1.74.3@sha256:623378…dfb # {"$imagepolicy": "flux-system:rclone"}`

### Bucket B — Renovate

Configured in `/renovate.json`. Watches Dockerfiles, Helm
charts, and (when not Flux-managed) container images. Renovate opens a
PR per bump.

`renovate.json` **disables Renovate** for the Bucket-A images (so Flux
owns them) and for everything in `ghcr.io/etherport/*` (Bucket C
below). ⚠️ The Docker disable list is **incomplete**: it omits the three
Bucket-A images added since the original write-up —
`velero-plugin-for-aws`, `cloudflared`, and `blackbox-exporter` — so add
them to the `packageRules` disable block (see "Adding a Bucket A image")
to avoid Renovate and Flux double-bumping. What's left for Renovate:

- Action versions in `.github/workflows/*.yml`
- Terraform provider versions
- Helm chart versions in HelmRelease specs
- Misc Docker image references not picked up by Flux

**When to use:** the dependency lives in source code, not a container
manifest, and we want a PR-driven bump cadence.

### Bucket C — Internally-built images on `:main`

Images we build ourselves and push to GHCR. The CI workflow tags both
`:main` (floating) and `:sha-<git-sha>` (immutable) — see e.g.
`.github/workflows/aws-s3-sync-image.yml`.

**Currently:**

| Image                                        | Built by workflow                       |
|----------------------------------------------|-----------------------------------------|
| `ghcr.io/etherport/aws-s3-sync:main`   | `.github/workflows/aws-s3-sync-image.yml` |
| `ghcr.io/etherport/cloudflare-ddns:main`  | `.github/workflows/cloudflare-ddns-image.yml` |
| `ghcr.io/etherport/ansible-runner:main`| `.github/workflows/ansible-runner-image.yml` |
| `ghcr.io/etherport/cloudwatch-to-loki:main`| `.github/workflows/cloudwatch-to-loki-image.yml` |

**Trade-off accepted:** `:main` is moving. Restarting a pod after a
new push pulls the new image. That's deliberate — `imagePullPolicy:
Always` is set on these so the pod always picks up the latest CI build.
Rollback is via `kubectl set image deployment/X X=...:sha-<old-sha>`.

**When to tighten:** if any of these workloads becomes load-bearing
enough that a bad CI push is a real outage risk, migrate the manifest
from `:main` → `:sha-<sha>` and switch to manual PR-driven bumps. The
sha tag is already published per-commit, so the migration is just
editing the tag in the manifest.

## How to add a new image

```
new image → decide bucket → wire it
```

### Adding a Bucket A image (Flux-managed)

1. Add an `ImageRepository` + `ImagePolicy` in
   `clusters/wind/image-automation/<name>.yaml` (or extend
   `base-images.yaml` for general-purpose base images).
2. In the manifest using the image, write the image tag at the version
   you want as the starting point and append the policy marker:
   `image: foo/bar:1.2.3 # {"$imagepolicy": "flux-system:<policy-name>"}`
3. Add an entry under "Currently managed" above.
4. Add the package to the Renovate disable list in `renovate.json` so
   you don't end up with both bumping it.

### Adding a Bucket B image (Renovate-managed)

1. Just reference the image at a specific tag in your manifest.
2. Renovate picks it up on the next run and will start opening PRs for
   patch/minor bumps according to `config:recommended`.
3. If you need to gate or skip a bump (e.g. major version with breaking
   changes), add a `packageRules` entry in `renovate.json`.

### Adding a Bucket C image (built here)

1. Build workflow goes in `.github/workflows/<name>-image.yml` — must
   emit both `:main` and `:sha-${{ github.sha }}` tags.
2. Manifest uses `:main` + `imagePullPolicy: Always`.
3. If rollback matters, document the sha tag pattern in the workflow's
   header comment and link to it from the workflow that consumes the
   image.

## Anti-patterns to flag in review

> Since 2026-06-28 the first two are not just review nits — **Kyverno ENFORCES them at
> admission** (M73, `platform/kubernetes/kyverno/`): a workload with a `:latest` or
> untagged image is **denied** by `disallow-latest-tag` / `require-image-tag`.

- `image: foo` (no tag → defaults to `:latest`) — **rejected by Kyverno**
- `image: foo:latest` — **rejected by Kyverno**; `foo:stable` / `foo:edge` pass admission but are still policy violations here
- `image: foo:main` for an image **not in Bucket C** (we don't trust
  upstream's main)
- A Bucket A image without the `# {"$imagepolicy": ...}` marker —
  Flux can't see it
- A Bucket A image whose tag has drifted from what Flux would currently
  pick (someone hand-edited and broke the automation loop) — Flux
  rewrites it next reconcile, but the manual edit suggests confusion
  about ownership

## Operations

- **Flux image-update-automation cadence**: 24h scan interval for the
  base-images ImageRepository. App-specific ones vary; see
  `clusters/wind/image-automation/<app>.yaml`.
- **Where Flux records its work**: each successful bump produces a
  commit on the `main` branch authored by the Flux bot ID.
- **What to do if you find an unmanaged moving tag**: open a PR
  re-classifying it into one of the three buckets. Don't just pin to
  a version and call it done — make the management explicit so the
  next person doesn't have to re-discover the policy.

## Last audit

2026-06-28 — re-verified against `clusters/wind/image-automation/`,
`renovate.json`, and the `etherport` GHCR org after H30 (digest
pinning, 2026-06-24) and the `cue` `:latest`-tracking automation landed.
Bucket A now also covers `cloudflared`, `blackbox-exporter`, and `cue`;
Bucket C gained `cloudwatch-to-loki`. Noted gap: the `renovate.json`
Docker disable list omits `velero-plugin-for-aws`, `cloudflared`, and
`blackbox-exporter`. (Prior audit 2026-05-22 confirmed the
service-status-report cronjob's Python image carries the `python-slim`
ImagePolicy marker so Flux owns its bump cadence.)
