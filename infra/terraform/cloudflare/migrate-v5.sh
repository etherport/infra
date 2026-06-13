#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# M69 — Cloudflare provider v4 -> v5 STATE MIGRATION (gated, windowed).
#
# The v5 provider is a ground-up rewrite; v4 state is NOT upgradeable in place.
# Safe path: `terraform state rm` every cloudflare_* resource, then re-`import`
# each one fresh under its v5 type/address. Real CF objects are never touched by
# rm/import — only the .tfstate mapping changes.
#
# RUN THIS IN A MAINTENANCE WINDOW, on branch `cf-provider-v5-migration`, after
# the v5 HCL is in place (it is — see main.tf/alexa-service-token.tf). It is
# heavily gated: it generates import blocks + removes old state, then STOPS for
# you to review `terraform plan` before any apply.
#
# Prereqs (headless from the mini): age key on disk; homelab AWS profile;
# CLOUDFLARE_API_TOKEN reachable (SOPS bundle). The wrapper below loads them.
#
#   ./migrate-v5.sh prepare    # capture IDs, write imports, rm old state
#   terraform plan -no-color -parallelism=2     # REVIEW: expect imports + ~0 changes
#   terraform apply -parallelism=2               # only after plan looks right
#   ./migrate-v5.sh cleanup    # remove generated_imports.tf
#
# ⚠️  READ THE GOTCHAS AT THE BOTTOM before applying — esp. the tunnel_secret
#     rotation risk and the Access-policy inline reconciliation.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"  # repo root: infra(repo)/infra/terraform/cloudflare -> up 3
IMPORTS_FILE="$HERE/generated_imports.tf"
BACKUP_DIR="$HERE/.migrate-v5-backup"

load_creds() {
  export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
  export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(sops -d "$ROOT/infra/ansible/playbooks/secrets/homelab-ops.sops.yaml" | sed -n 's/^cloudflare_api_token: *//p' | tr -d '"')}"
  local zjson
  zjson="$(curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" 'https://api.cloudflare.com/client/v4/zones?name=etherport.net')"
  export TF_VAR_cloudflare_zone_id="${TF_VAR_cloudflare_zone_id:-$(printf '%s' "$zjson" | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['id'])")}"
  export TF_VAR_cloudflare_account_id="${TF_VAR_cloudflare_account_id:-$(printf '%s' "$zjson" | python3 -c "import json,sys;print(json.load(sys.stdin)['result'][0]['account']['id'])")}"
  [ -n "$TF_VAR_cloudflare_zone_id" ] && [ -n "$TF_VAR_cloudflare_account_id" ] || { echo "ERROR: could not resolve zone/account id" >&2; exit 1; }
}

prepare() {
  cd "$HERE"
  [ "$(git -C "$ROOT" branch --show-current)" = "cf-provider-v5-migration" ] || { echo "ERROR: not on cf-provider-v5-migration branch" >&2; exit 1; }
  load_creds
  terraform init -input=false -no-color >/dev/null

  # 1. Back up live state BEFORE touching anything (RAW state — provider-independent;
  #    `terraform show -json` can't marshal v4 schema-version-3 state under the v5
  #    provider, so we parse the raw pulled state instead).
  mkdir -p "$BACKUP_DIR"
  local statefile="$BACKUP_DIR/state-v4-$(date +%s).json"
  terraform state pull > "$statefile"
  echo "✓ state backed up to $statefile"

  # 2. Capture every cloudflare_* resource's address+id from the raw state and
  #    emit (a) import blocks for the v5 addresses and (b) the list of old
  #    addresses to remove. Access POLICIES are folded inline into apps in v5 →
  #    removed but NOT imported. random_id / aws_* are left untouched.
  python3 - "$statefile" "$IMPORTS_FILE" "$BACKUP_DIR/rm-list.txt" \
           "$TF_VAR_cloudflare_zone_id" "$TF_VAR_cloudflare_account_id" <<'PY'
import json, sys
state_path, imports_path, rmlist_path, zone_id, account_id = sys.argv[1:6]
data = json.load(open(state_path))

# old type -> (new type, import-id template). {z}=zone_id {a}=account_id {id}=resource id
RENAME = {
    "cloudflare_record":        ("cloudflare_dns_record",                          "{z}/{id}"),
    "cloudflare_tunnel_config": ("cloudflare_zero_trust_tunnel_cloudflared_config","{a}/{id}"),
    "cloudflare_tunnel":        ("cloudflare_zero_trust_tunnel_cloudflared",       "{a}/{id}"),
}
# same-type resources whose schema changed — rm + re-import at the SAME address.
SAME = {
    "cloudflare_zone":                           "{id}",           # id == zone id
    "cloudflare_zone_dnssec":                    "{z}",
    # Access app + service-token v5 imports need the accounts/ discriminator:
    # "<{accounts|zones}/{id}>/<app_id>". Tunnel/config use plain {a}/{id}.
    "cloudflare_zero_trust_access_application":  "accounts/{a}/{id}",
    "cloudflare_zero_trust_access_service_token":"accounts/{a}/{id}",
}
# folded inline into the app's `policies` in v5 — remove, do NOT import.
DROP = {"cloudflare_zero_trust_access_policy"}

def addr(t, name, key):
    a = f"{t}.{name}"
    if key is None: return a
    return f'{a}["{key}"]' if isinstance(key, str) else f"{a}[{key}]"

imports, rm = [], []
for r in data["resources"]:
    if r.get("mode") != "managed":
        continue
    t, name = r["type"], r["name"]
    for inst in r["instances"]:
        key = inst.get("index_key")
        rid = inst.get("attributes", {}).get("id", "")
        old = addr(t, name, key)
        if t in DROP:
            rm.append(old); continue
        if t in RENAME:
            newt, tmpl = RENAME[t]; newaddr = newt + old[len(t):]
        elif t in SAME:
            newt, tmpl, newaddr = t, SAME[t], old
        else:
            continue  # non-cloudflare (random_id, aws_*) — leave untouched
        rm.append(old)
        imports.append((newaddr, tmpl.format(z=zone_id, a=account_id, id=rid)))

with open(imports_path, "w") as f:
    f.write("# GENERATED by migrate-v5.sh — delete after apply (./migrate-v5.sh cleanup).\n")
    for a, iid in sorted(imports):
        f.write(f'import {{\n  to = {a}\n  id = "{iid}"\n}}\n\n')

open(rmlist_path, "w").write("\n".join(rm) + "\n")
print(f"  import blocks: {len(imports)}   state rm: {len(rm)} (incl. {sum('access_policy' in a for a in rm)} inline-folded policies)")
PY
  echo "✓ wrote $IMPORTS_FILE"

  # 3. Remove the old-typed resources from state (real objects untouched).
  while IFS= read -r addr; do
    [ -z "$addr" ] && continue
    terraform state rm "$addr" >/dev/null && echo "  rm  $addr"
  done < "$BACKUP_DIR/rm-list.txt"

  cat <<'NEXT'

────────────────────────────────────────────────────────────────────────────
PREPARE DONE. Now REVIEW before applying:

  terraform plan -no-color -parallelism=2 | tee plan-v5.txt

  Expect: "<N> to import, 0 to add, 0 to change, 0 to destroy" (or only benign
  in-place tweaks). INVESTIGATE any "to add"/"destroy"/"replace" — that means an
  address or import-id is wrong; restore with:
      terraform state push <newest .migrate-v5-backup/state-v4-*.json>
  and re-check before retrying.

  When the plan is clean:
  terraform apply -parallelism=2          # imports everything under v5
  ./migrate-v5.sh cleanup                  # remove generated_imports.tf
────────────────────────────────────────────────────────────────────────────
NEXT
}

cleanup() { rm -f "$IMPORTS_FILE" && echo "✓ removed $IMPORTS_FILE"; }

case "${1:-}" in
  prepare) prepare ;;
  cleanup) cleanup ;;
  *) echo "usage: $0 {prepare|cleanup}" >&2; exit 2 ;;
esac

# -----------------------------------------------------------------------------
# ⚠️  GOTCHAS — read before `terraform apply`:
#
# 1. TUNNEL SECRET ROTATION (highest risk). The tunnel is imported, but its
#    `tunnel_secret` is write-only — the API never returns it, so after import
#    state has no secret and `plan` will want to SET it from
#    random_id.tunnel_secret.b64_std. random_id keeps its value (it's untouched
#    in state), so the secret is the SAME bytes — BUT applying it re-issues the
#    tunnel token. If `plan` shows the tunnel being updated/replaced on
#    tunnel_secret, STOP: either add `lifecycle { ignore_changes = [tunnel_secret] }`
#    to the tunnel resource, OR plan to rotate + redeploy
#    platform/kubernetes/cloudflared/01-tunnel-token.sops.yaml
#    (terraform output -raw tunnel_token) in the same window so cloudflared
#    reconnects. Do NOT apply a silent secret change.
#
# 2. ACCESS POLICIES (folded inline). The 9 standalone policies are removed from
#    state and NOT imported — they now live in each app's `policies` list. After
#    importing the apps, `plan` reveals whether the v5 provider read the live
#    attached policies into `policies`. If it shows the apps wanting to
#    add/replace policies, the live attachment didn't round-trip — reconcile by
#    hand (match precedence/decision/include) until plan is zero-diff. This is
#    the part personal-web's DNS-only run does NOT exercise, so it's first-touch
#    here. Apply Access LAST and confirm you can still log in to one app
#    (e.g. wiki) before walking away.
#
# 3. SERVICE TOKEN SECRET. The Alexa service token is imported by id, but
#    `client_secret` is creation-only — `terraform output alexa_service_token_client_secret`
#    will be empty after import. That's fine: the Alexa Lambda already holds the
#    working secret. Only if you need it again do you rotate (recreate) the token
#    and update the Lambda env.
#
# 4. DNS NAME FQDN. v5 records use the full FQDN as `name`. The import maps by
#    record id (not name), so this is safe — but if any record shows a name diff
#    on plan, confirm the v5 `name = "${key}.${zone}"` matches the live record.
# -----------------------------------------------------------------------------
