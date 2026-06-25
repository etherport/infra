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

**Phase 1 — stand up step-ca.** Deploy step-ca on the chosen host (systemd). Init the **SSH CA**
(user CA + host CA keys). Protect the CA key (encrypted; password via SOPS). Add the OIDC (Authentik)
+ JWK + SSHPOP provisioners. *No host touched yet — zero impact.*

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
