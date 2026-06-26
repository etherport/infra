# M76 — short-lived identity-bound SSH (step-ca hybrid) (plan)

**Status:** 📋 PLANNED (decided 2026-06-25 — **step-ca SSH CA hybrid**, chosen over
Tailscale-SSH-for-fleet). **Tier/effort:** MED/M. Pairs with **M71** ("kill standing creds";
M75 already did the in-cluster IRSA leg).

**Goal:** replace the single long-lived shared key **`id_ed25519_homelab`** (`automation@homelab`)
for SSH to the **13 Ubuntu hosts** (8 k8s nodes + 5 standalone VMs incl. devbox + the PVE host)
with **short-lived, identity-bound** credentials, removing it as a single stealable standing secret.
Appliances are a **hard carve-out** (see below).

---

## Why step-ca, not Tailscale-SSH (the decision)

- The two heavy SSH consumers are **headless**: the **Claude devbox agent** and **CI ansible** on
  the lifecycle gh-runner. The current Tailscale ACL (`infra/tailscale/policy.hujson`) is
  **`action: check`** (interactive Google re-auth — *breaks* headless), and a live `tailscale status`
  shows **the fleet is NOT on the tailnet** (only devbox + the offline `vpn-local` subnet router are;
  the ACL `dst` is `autogroup:self`, excluding tagged nodes). Tailscale-SSH-for-fleet = install
  tailscaled on 13 hosts **and** rework the ACL.
- **The LAN / no-Tailscale path is the decider.** Tailscale SSH only governs the tailnet (`100.x`)
  transport — `ssh ubuntu@10.10.201.50` over the **LAN IP bypasses it** and falls back to the static
  key. **step-ca certs are transport-agnostic** (`TrustedUserCAKeys`): a short-lived cert authenticates
  over LAN IP, tailnet, or VPN identically — and fits ansible cleanly (one trust anchor, no per-host
  key distribution).

**Hybrid shape:** step-ca = primary SSH auth for the 13 Ubuntu hosts; **Tailscale-SSH (`check`)
retained** for interactive human *remote* convenience (second independent path, already IaC'd);
**PVE console + IPMI = break-glass**; **appliances keep scoped legacy keys**.

## Hard constraints / honest caveats

- **Appliance carve-out (by construction):** UDM Pro `10.10.200.1`, UNAS `10.10.209.10`,
  Windprotect `10.10.212.10`, PDU/UPS — vendor firmware, can't trust a CA or run tailscaled. They
  keep the existing **scoped** keys (`unifi-cert-sync@homelab`, `udm_ssh_*` password, the
  command-restricted `ai-advisor` key). Out of M76's reach. M76 ≠ "no long-lived keys anywhere."
- **Partial "kill standing creds" win:** step-ca trades the standing SSH key for (a) the **CA signing
  key** (new crown-jewel) and (b) a **JWK-provisioner password** the headless flows use to mint certs
  (new standing bootstrap secret, SOPS-stored). Net security gain: the minted creds are short-lived +
  identity-bound + the key no longer sits on 3 disks; but it's a *trade*, not elimination.
- **SPOF / break-glass is mandatory:** step-ca (+ Authentik for the human OIDC path) become SSH
  SPOFs. **Run step-ca OFF the k8s cluster** (a small always-on host / VM via systemd) so a cluster
  outage doesn't strand node SSH (avoids the circular dependency). Keep credential-free recovery:
  **PVE noVNC / `qm terminal`** for every guest (incl. devbox, VM 1005) + **IPMI `10.10.200.21`** for
  the PVE host. Set a **console break-glass password** on each host (cloud-init users are key-only →
  serial console is otherwise unusable for recovery).

## Coverage matrix
- **YES (step-ca):** 8 k8s nodes (cp1-3 .50-.52, w1-4 .53-.56, gpu1 .60), 5 standalone VMs
  (dns-fallback .6, vpn-local .15, gh-runner .30, asterisk-sbc .40, devbox .45), PVE host
  (root@pve). All editable OpenSSH; ansible already pushes sshd config (`base.yml`, `pve-sshd.yml`).
- **NO (legacy auth stays):** UDM, UNAS, Windprotect, PDU/UPS.

---

## Phased plan (safe rollout — fallback stays until the new path is proven)

**Phase 0 — decisions/prep.** Pick step-ca host (recommend a small **standalone VM** via the
existing `standalone-vms` TF, or the always-on mini — NOT in-cluster). Pick provisioners: **OIDC →
Authentik** (`auth.wind.etherport.net`) for humans; **JWK** for headless (devbox agent + CI). Decide
cert TTLs (user ~8–16 h interactive, ~minutes for headless renew-loop; host certs long with SSHPOP
renewal).

**Phase 1 — stand up step-ca. ✅ DEPLOYED 2026-06-26.** VM 1006 provisioned (CI), playbook run →
**step-ca is `active` on `https://10.10.201.46:8443`**, provisioners **`admin`/`sshpop`/`headless`(JWK)**,
SSH user+host CA keys present. **Root CA fingerprint (clients bootstrap trust with this — NOT secret):**
`a37b7b1622157ecd6687dc953f95cbb49d152fe9819ed0b54aa56f4f9689cf67`
(`step ca bootstrap --ca-url https://step-ca.wind.etherport.net:8443 --fingerprint a37b7b16…89cf67`).
Two understood follow-ups (neither blocks the headless path):
- **OIDC human provisioner deferred** — `step ca provisioner add --type OIDC` validates the Authentik
  discovery endpoint at add-time, but **a VLAN-201 host can't reach the MetalLB BGP VIP `10.10.201.70`
  (Traefik, where `auth.wind.etherport.net` lives) on its own subnet** — `no route to host` (BGP-only,
  no L2/ARP same-subnet; the grafana endpoint is equally unreachable that way, so it's a network
  constraint not a config bug). The playbook's OIDC add is **best-effort** and will land automatically
  once step-ca can reach Authentik. Fix options: a `10.10.201.70/32 via 10.10.201.1` route on step-ca
  (UDM hairpin), or reach Authentik via a non-VIP path. The Authentik `step-ca` OIDC app + secret are
  already in IaC (blueprint applied).
- **DNS** `step-ca.wind.etherport.net A 10.10.201.46` added to Technitium (status ok); propagation
  across the HA pair + the VM resolver cache still settling — clients can use the `.46` IP meanwhile
  (the CA cert carries the IP SAN).

Host = a **dedicated off-cluster standalone VM `step-ca` (1006, 10.10.201.46)**. Built + validated:
- `infra/terraform/proxmox/standalone-vms/main.tf` — VM 1006 (1 vCPU / 1 GB / 15 GB). `validate` OK.
- `infra/terraform/proxmox/firewall/standalone-vms.tf` — M77 firewall for 1006 (baseline SSH/9100 +
  CA API `:8443` from the Servers VLAN cert-clients + tailnet). `validate` OK.
- `infra/ansible/playbooks/step-ca.yml` — idempotent step-ca standup (step-ca 0.30.2 / step-cli
  0.30.6, sha256-pinned `.deb`; `step` system user; hardened systemd `:8443`; `step ca init --ssh`
  guarded on ca.json; 3 provisioners: **`authentik` OIDC** human path, **`headless` JWK** automation,
  **`sshpop`** host-cert renewal; SIGHUP reload; shreds transient pw files; prints root-CA
  fingerprint). `--syntax-check` PASSED.
- `infra/ansible/playbooks/secrets/step-ca.sops.yaml` — SOPS-encrypted `ca_password` / `jwk_password`
  / `oidc_client_secret` (generated).
- `platform/kubernetes/authentik/40-blueprints.yaml` — `step-ca` OIDC app (redirect = the `step` CLI
  loopback `:10000`); secret `AUTHENTIK_STEPCA_CLIENT_SECRET` added to `30-authentik-secret.sops.yaml`
  (matches the SOPS `oidc_client_secret`). kustomize builds.
- `infra/ansible/inventory/wind/inventory.ini` — `step-ca` host + `[step_ca]` group.

  **DEPLOY (the authorized next step — provisions a new VM):** (1) TF apply `standalone-vms` (provision
  VM 1006) — like M77, a CI dispatch needing authorization; (2) TF apply `firewall` (its rules); (3)
  add DNS `step-ca.wind.etherport.net A 10.10.201.46` (cluster Technitium); (4) Flux reconcile so the
  Authentik blueprint applies (creates the OIDC app); (5) run `ansible-playbook -i inventory/wind
  playbooks/step-ca.yml` → step-ca up, capture the **root-CA fingerprint** (clients bootstrap trust
  with it). *No existing host is touched — additive.* Then Phase 2.

**Phase 2 — trust the CA on ONE proof host (additive, in parallel with the existing key).** New
ansible role pushes `TrustedUserCAKeys` + `HostKey` + `HostCertificate` (sshd drop-in) to one host
(e.g. a worker, or devbox). Host-cert auto-renew via an **SSHPOP systemd timer**
(`needs-renewal --expires-in=8h && step ssh renew && systemctl reload ssh`). Client `@cert-authority`
line in `known_hosts`. **The `automation@homelab` key stays authorized** — both paths work.

**Phase 3 — prove the headless flow end-to-end.** On the devbox: a **JWK renew-loop** (systemd timer,
`STEP_CA_PASSWORD` from SOPS) mints a minutes-long **user cert**; SSH to the proof host using the
**cert, not the static key** (force-disable the key in a test to confirm). Prove CI ansible can do
the same (cert presented non-interactively). This is the make-or-break gate — do not proceed until
headless renewal is demonstrably non-interactive.

**Phase 4 — roll CA trust to all 13 hosts.** Ansible-push `TrustedUserCAKeys`/host-cert to every
node/VM + PVE, still **in parallel** with the existing key. Set the **console break-glass password**
on each (cloud-init drop-in / ansible). Document break-glass (PVE console + IPMI) in a runbook.

**Phase 5 — cut over + remove the standing key.** Switch the devbox agent SSH config + CI ansible to
the cert path; verify the whole fleet works on certs (incl. `k8s-node-patch.yml`,
`ansible-vm-fleet.yml`, kubespray SSH). **Then remove the `automation@homelab` authorized_keys entry
host-by-host** (cloud-init `keys=` → ansible-managed removal), and from the 4 hardcoded deploy points
(TF cloud-init, Packer, ansible, AWS cloud-init) + the SOPS/GH-secret holders — leaving **only**: the
appliance scoped keys, and **optionally** a SOPS-sealed emergency key authorized on **PVE root only**
(belt-and-suspenders; IPMI already covers it).

**Phase 6 — human path + docs.** Confirm Tailscale-SSH `check` mode still serves interactive remote
human access (already IaC'd). Update CLAUDE.md (§4 access), the SSH runbook, outstanding-work (M76 ✅
for the Ubuntu fleet + the explicit appliance carve-out), session-log. Revisit M71 (the AWS analog)
under the same theme.

## Key risks
- **Self-lockout** (dominant): never remove the static key from a host before the cert path is proven
  there; keep the parallel fallback through Phase 4; PVE console/IPMI is the net.
- **Crown-jewel CA key** + **JWK provisioner password** are new high-value standing secrets — guard
  in SOPS, plan rotation (CA rotation = re-trust every host).
- **User certs aren't renewable** (smallstep design) → headless = a re-issue loop, not renew.
- **step-ca/Authentik SSH SPOF** → break-glass (console/IPMI) is mandatory, not optional.
- The **4 hardcoded pubkey deploy points** must all be updated at cutover or a rebuilt host
  re-authorizes the dead key.
