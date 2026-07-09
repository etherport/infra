#!/usr/bin/env bash
# M76: keep a fresh step-ca SSH **user** cert on the devbox so the Claude agent
# (and any interactive use) authenticates to the homelab with a short-lived cert
# instead of the standing id_ed25519_homelab key. Run by a user systemd timer
# (~/.config/systemd/user/step-ssh-renew.timer) every few hours.
#
# The devbox already holds the jwk_password (SOPS) + a bootstrapped ~/.step CA
# context, so it mints non-interactively via the headless JWK provisioner.
# Cert -> ~/.ssh/id_homelab_cert (+ -cert.pub); ssh_config offers it ahead of the
# static key. 13h validity, renewed well inside that window.
set -euo pipefail

REPO="${HOMELAB_REPO:-/home/ubuntu/code/infra}"
SOPS_FILE="${REPO}/infra/ansible/playbooks/secrets/step-ca.sops.yaml"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-/home/ubuntu/.config/sops/age/keys.txt}"
CERT_KEY="${HOME}/.ssh/id_homelab_cert"

pwfile="$(mktemp)"
trap 'shred -u "$pwfile" 2>/dev/null || rm -f "$pwfile"' EXIT
sops -d "$SOPS_FILE" 2>/dev/null | sed -n 's/^jwk_password:[[:space:]]*//p' | tr -d '"' > "$pwfile"
[ -s "$pwfile" ] || { echo "step-ssh-renew: failed to read jwk_password from SOPS" >&2; exit 1; }

# Mint a 13h user cert valid for the shared ubuntu/root logins. --insecure +
# --no-password = no passphrase on the cert key (it's short-lived + local).
# NB: the cert's PRINCIPALS are pinned to [ubuntu,root] by the `headless`
# provisioner's CA-side SSH template (files/step-ca/headless_user.tpl) — step-cli
# 0.30.6 does NOT flow these --principal flags through for JWK certs (they'd come
# out empty = valid for ANY user), so the template is what actually constrains it.
# The flags are kept as documentation of intent (harmless; the template wins).
step ssh certificate ubuntu "$CERT_KEY" \
  --provisioner headless --provisioner-password-file "$pwfile" \
  --principal ubuntu --principal root \
  --not-after 13h --no-password --insecure --force >/dev/null
chmod 600 "$CERT_KEY"
echo "step-ssh-renew: minted $(ssh-keygen -L -f "${CERT_KEY}-cert.pub" 2>/dev/null | awk '/Valid:/{$1="";print "valid"$0}')"

# M133: expose the freshly-minted cert's expiry as a node_exporter textfile metric
# so Prometheus can alert if THIS renew loop stalls (timer disabled, linger lost,
# SOPS/CA unreachable) — a silent failure today until an SSH op fails ~13h later.
# The devbox is scraped as instance="devbox" (01-external-scrape-config), so the
# metric carries that label; alerts DevboxSSHCertExpiringSoon / -MetricAbsent live
# in platform/kubernetes/monitoring/02-external-alerts.yaml. Atomic write.
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
if [ -d "$TEXTFILE_DIR" ] && [ -w "$TEXTFILE_DIR" ]; then
  not_after_str="$(ssh-keygen -L -f "${CERT_KEY}-cert.pub" 2>/dev/null | sed -n 's/.*Valid:.* to \([0-9T:-]*\).*/\1/p')"
  not_after_epoch="$(date -d "${not_after_str/T/ }" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  tmp="$(mktemp "${TEXTFILE_DIR}/step_ssh_cert.prom.XXXXXX")"
  cat > "$tmp" <<PROM
# HELP step_ssh_cert_not_after_seconds Unix expiry (NotAfter) of the devbox step-ca SSH user cert.
# TYPE step_ssh_cert_not_after_seconds gauge
step_ssh_cert_not_after_seconds ${not_after_epoch}
# HELP step_ssh_cert_renew_last_success_timestamp_seconds Unix time of the last successful cert mint.
# TYPE step_ssh_cert_renew_last_success_timestamp_seconds gauge
step_ssh_cert_renew_last_success_timestamp_seconds ${now_epoch}
PROM
  chmod 644 "$tmp"
  mv -f "$tmp" "${TEXTFILE_DIR}/step_ssh_cert.prom"
fi
