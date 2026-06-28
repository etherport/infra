# UniFi cert auto-sync

K8s CronJob that pushes the cert-manager-issued wildcard cert for
`*.wind.etherport.net` to each UniFi device weekly, replacing the
self-signed (and previously hand-managed acme.sh-on-device) certs.

## Devices in scope

| Name | Host | Notes |
|------|------|-------|
| udm  | `10.10.200.1` (gw) | UDM Pro Max — runs Network + Talk apps |
| protect | `10.10.212.10` | UniFi Protect appliance |
| sequoia | `sequoia.wind.etherport.net` (10.10.209.10) | UniFi UNAS Pro |
| pve | `10.10.200.41` | Proxmox VE host — NOT UniFi OS (pveproxy paths, `:8006`) |

The three UniFi-OS devices share an identical cert path + restart command:
`/data/unifi-core/config/unifi-core.{crt,key}` + `systemctl restart unifi-core`.
**Proxmox VE is the exception:** `/etc/pve/local/pveproxy-ssl.{pem,key}` +
`systemctl restart pveproxy`, verified on port `:8006`.

## Architecture

```
cert-manager  →  Secret traefik/wildcard-wind-etherport-net-rsa-tls
                              │
                              │ (kubectl get, cross-namespace RBAC)
                              ▼
                       CronJob (weekly)
                              │
                              │ SSH + SCP
                              ▼
              ┌───────────────┼───────────────┬───────────────┐
              ▼               ▼               ▼               ▼
            UDM            Protect          UNAS             PVE
        (UniFi OS: unifi-core.{crt,key} + `systemctl restart unifi-core`)
        (PVE: pveproxy-ssl.{pem,key} + `systemctl restart pveproxy`, :8006)
```

- **Source of truth:** cert-manager. The RSA wildcard is a "classic" ~90-day
  Let's Encrypt cert that renews ~30 days before expiry via Cloudflare DNS-01
  (migrated off Route53 2026-05-27).
- **Cert type:** RSA 2048. cert-manager issues an RSA-keyed wildcard
  specifically for UniFi devices (`wildcard-wind-etherport-net-rsa`)
  alongside the ECDSA wildcard Traefik uses. **UniFi OS unifi-core
  silently rejects ECDSA certs and regenerates a self-signed
  `unifi.local` default — discovered the hard way on 2026-05-17.**
- **Cadence:** weekly (Mon 04:00 local). cert-manager renews ~30d before
  expiry, but weekly cadence catches firmware-upgrade resets within 7d.
- **Idempotent:** computes SHA256 of (crt+key) and skips push if remote
  matches. Restart only fires when cert actually changed.
- **Verification:** post-push, opens HTTPS to the device and confirms the
  served cert's fingerprint matches what we pushed.
- **Observability:** pushes metrics to in-cluster Prometheus pushgateway.
  See `05-prometheusrule.yaml` for the 3 alerts.

## One-time setup (per device)

1. **Enable SSH on the device** (UDM/Protect/UNAS UI → Settings → System
   → Console → Enable SSH). Set a root password if not already set.

2. **Add the cert-sync SSH public key** to `/root/.ssh/authorized_keys`:

   ```bash
   # On a workstation that can SSH into the device:
   ssh-copy-id -i /tmp/unifi-cert-sync.pub root@10.10.200.1
   # repeat for 10.10.212.10 and sequoia.wind.etherport.net
   ```

   The dedicated public key (committed to 1Password as "UniFi cert-sync
   SSH key (public)") is:

   ```
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICaABoTxNhGnkW/FqpF9ztYGAv3efgAMZnUWoH66Ythz unifi-cert-sync@homelab
   ```

3. **Remove old acme.sh / uacme** from each device if present (it'll
   fight the CronJob's cert installs). On UniFi OS:

   ```bash
   ssh root@<device> 'rm -rf ~/.acme.sh /etc/acme.sh /var/lib/acme.sh 2>/dev/null;
                       systemctl disable --now acme.sh.timer 2>/dev/null'
   ```

## Initial bootstrap (one-time, by an operator)

1. **Generate the keypair** (already done — see `/tmp/unifi-cert-sync*`):
   ```bash
   ssh-keygen -t ed25519 -f /tmp/unifi-cert-sync \
     -C "unifi-cert-sync@homelab" -N "" -q
   ```

2. **Collect known_hosts** (avoid TOFU prompts in the CronJob):
   ```bash
   ssh-keyscan -t ed25519 10.10.200.1 10.10.212.10 sequoia.wind.etherport.net \
     > /tmp/unifi-cert-sync.known_hosts
   ```

3. **Populate the SOPS Secret**:
   ```bash
   cd platform/kubernetes/unifi-cert-sync
   cp 02-secret.sops.yaml.template 02-secret.sops.yaml
   # Edit: paste contents of /tmp/unifi-cert-sync (private key) and
   #       /tmp/unifi-cert-sync.known_hosts under stringData.
   sops --encrypt --in-place 02-secret.sops.yaml
   ```

4. **Store the keypair in 1Password** (so future operators can fetch):
   - Title: `UniFi cert-sync SSH key`
   - private key field: contents of `/tmp/unifi-cert-sync`
   - public key field: contents of `/tmp/unifi-cert-sync.pub`
   - notesPlain: known_hosts entries + list of authorized devices

5. **Commit + push** — Flux picks up + deploys the CronJob.

6. **Trigger initial run** (don't wait until next Monday):
   ```bash
   kubectl -n unifi-cert-sync create job --from=cronjob/unifi-cert-sync \
     unifi-cert-sync-initial
   kubectl -n unifi-cert-sync logs -l job-name=unifi-cert-sync-initial -f
   ```

7. **Verify each device's served cert**:
   ```bash
   for host in 10.10.200.1 10.10.212.10 sequoia.wind.etherport.net; do
     echo "=== $host ==="
     echo | openssl s_client -connect $host:443 -servername wind.etherport.net \
       2>/dev/null | openssl x509 -noout -subject -issuer
   done
   ```
   Subject should be `CN=*.wind.etherport.net`, issuer should be Let's Encrypt.

## Operating

- **Rotate the cert-sync SSH key:** generate a new keypair, push new
  public key to each device, re-encrypt the SOPS secret with the new
  private key, commit. Flux rolls the CronJob.
- **Force a sync (off-schedule):** `kubectl -n unifi-cert-sync create job
  --from=cronjob/unifi-cert-sync unifi-cert-sync-adhoc-$(date +%s)`
- **Suspend syncing temporarily:** `kubectl -n unifi-cert-sync patch
  cronjob unifi-cert-sync -p '{"spec":{"suspend":true}}'`
- **Pause for UDM firmware update:** the next post-update sync will
  restore the cert. UI shows self-signed for up to ~7d in worst case.

## Disaster recovery

If the CronJob is broken AND the cert expires:

1. Manually run cert-manager refresh: `kubectl -n traefik delete
   certificate wildcard-wind-etherport-net-rsa` (it'll recreate from the
   resource and renew the cert). ⚠️ Use the **RSA** cert — UniFi OS silently
   rejects the ECDSA `wildcard-wind-etherport-net`.
2. SSH to each device and copy the new cert by hand from the **RSA** secret:
   ```bash
   kubectl -n traefik get secret wildcard-wind-etherport-net-rsa-tls \
     -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/crt
   kubectl -n traefik get secret wildcard-wind-etherport-net-rsa-tls \
     -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/key
   # UniFi-OS devices (udm / protect / sequoia):
   scp /tmp/crt root@10.10.200.1:/data/unifi-core/config/unifi-core.crt
   scp /tmp/key root@10.10.200.1:/data/unifi-core/config/unifi-core.key
   ssh root@10.10.200.1 'chmod 600 /data/unifi-core/config/unifi-core.key && systemctl restart unifi-core'
   # repeat for 10.10.212.10 and sequoia
   # Proxmox VE (pve) — different paths, pveproxy restart:
   scp /tmp/crt root@10.10.200.41:/etc/pve/local/pveproxy-ssl.pem
   scp /tmp/key root@10.10.200.41:/etc/pve/local/pveproxy-ssl.key
   ssh root@10.10.200.41 'systemctl restart pveproxy'
   ```

## Alerts (PrometheusRule)

| Alert | Severity | Triggers when |
|-------|----------|---------------|
| `UnifiCertSyncDeviceFailed` | warning | a specific device's push or verify failed for 10m |
| `UnifiCertSyncStale` | warning | no successful run in 14d (2 missed weeks + margin) |
| `UnifiWildcardCertExpiring` | critical | cert expires in <14d AND we haven't synced fresh |

## Known limitations / future work

- **No Talk-specific cert sync:** Talk uses a separate cert path on the
  UDM (`/data/unifi-core/talk/...`) — needs separate logic if you want
  Talk's web UI to also serve the wildcard. Not implemented yet.
- **SSH key rotation is manual:** no automated key-rotation pipeline.
  Generate a new key + roll it to each device's authorized_keys.
- **No HA:** single CronJob. If the pod crashloops, alerts fire after
  10m. Manual intervention required.

## See also

- `docs/planning/archive/udm-config-drift-2026-05-17.md` — the audit that
  identified the in-device acme.sh setup as a fragility risk.
- `platform/kubernetes/cloudflare-ddns/base/` — similar CronJob pattern.
