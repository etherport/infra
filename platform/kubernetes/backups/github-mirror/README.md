# github-repo-mirror — off-GitHub backup of all repos → NAS → S3

Nightly CronJob that mirrors **every repo owned by the `etherport` GitHub
account** into a single `git bundle` per repo on the NAS, from where the existing
`s3-sync-backups` job sweeps them to S3. This is the disaster-recovery copy of the
source of truth: until this existed, the only copies of the repos were GitHub plus
whatever working clones happened to be on the devbox/mini.

## Flow

```
GitHub (etherport, private)
   │  git clone --mirror  (00:40 PT, this CronJob)
   ▼
NAS  sequoia:/var/nfs/shared/Backups/repos/<name>.bundle   (one file per repo)
   │  aws s3 sync         (01:10 PT, existing s3-sync-backups)
   ▼
s3://archive.wind.etherport.net/objects/backups/repos/<name>.bundle
```

The mirror runs 30 min before the S3 sweep so each night's fresh bundles ship the
same night. Bundles are published atomically (write to `.tmp`, then `mv`) so the
sync never uploads a half-written file.

## Why bundles (not bare mirrors)

A `git bundle --all` is a **single file** containing the complete history and all
refs. That's ideal for the per-object S3 sync (one object per repo instead of
thousands of loose git objects), it's integrity-checkable (`git bundle verify`),
and restore is trivial. The bare `--mirror` clone is done in ephemeral scratch and
discarded; only the bundle is kept.

## Restore

```sh
# from the NAS share or the S3 object:
git clone infra.bundle infra
cd infra
git remote set-url origin git@github.com:etherport/infra.git
git push --mirror origin        # only if repopulating an empty GitHub repo
```

## The token

`github-mirror-token` (SOPS) holds a **fine-grained, read-only PAT** owned by the
`etherport` account:

- **Resource owner:** etherport
- **Repository access:** All repositories
- **Permissions:** *Contents: Read-only* (clone) + *Metadata: Read-only* (auto;
  needed to enumerate via `/user/repos`)

Nothing else. It cannot write, cannot touch Actions/secrets/settings.

### Rotating the PAT (it expires — GitHub fine-grained max is ~1 year, or the 90d
you set)

`GithubRepoMirrorStale` fires ~36h after the token dies, so a lapse is caught, but
rotate ahead of expiry. On the **devbox** (which holds the SOPS age key):

```sh
# 1. Mint a new fine-grained PAT on github.com (same scopes: Contents:read +
#    Metadata:read, all repos, owner etherport). Save it to a temp file.
# 2. Drop it into the encrypted secret WITHOUT it ever hitting git plaintext:
cd ~/code/infra
NEW=$(tr -d '[:space:]' < /path/to/new-pat)
cat > platform/kubernetes/backups/github-mirror/01-token.sops.yaml <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: github-mirror-token
  namespace: backups
type: Opaque
stringData:
  token: ${NEW}
YAML
unset NEW
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -e -i \
  platform/kubernetes/backups/github-mirror/01-token.sops.yaml
grep -q github_pat_ platform/kubernetes/backups/github-mirror/01-token.sops.yaml \
  && echo "STILL PLAINTEXT — abort" || echo "encrypted OK"
shred -u /path/to/new-pat            # remove the plaintext copy
# 3. commit + push; Flux rolls the in-cluster secret. Next nightly run uses it.
git add platform/kubernetes/backups/github-mirror/01-token.sops.yaml
git commit -m "chore(backups): rotate github-repo-mirror PAT" && git push
# 4. verify, then EXPIRE the old PAT on github.com:
kubectl -n backups create job --from=cronjob/github-repo-mirror ghm-rotate-test
kubectl -n backups logs -f job/ghm-rotate-test   # expect "done — N/N repos bundled"
```

The Secret is the single source of truth (SOPS-encrypted in git → Flux → cluster).
There is no copy anywhere else; the plaintext PAT lives only on GitHub's side and
transiently on the devbox during rotation (shredded immediately).

## Image

`alpine/git` — busybox `wget` does HTTPS + `Authorization` headers, so enumeration
needs no curl/jq and the job needs no custom image or runtime installs. The token
is kept out of the URL, reflog and `ps` via a git `http.extraHeader` written under
an ephemeral `HOME=/work`.

## Operate

```sh
# after landing the real PAT, activate:
kubectl -n backups patch cronjob github-repo-mirror --type merge -p '{"spec":{"suspend":false}}'
# run once now (don't wait for 00:40 PT):
kubectl -n backups create job --from=cronjob/github-repo-mirror github-repo-mirror-manual
kubectl -n backups logs -f job/github-repo-mirror-manual
```

`GithubRepoMirrorStale` (warning) fires if no run succeeds in >36h; an individual
failed run also trips the cluster's `KubeJobFailed`. The staleness alert is silent
while the CronJob is intentionally suspended.
