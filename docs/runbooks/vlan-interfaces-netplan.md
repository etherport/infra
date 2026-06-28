# VLAN Interfaces Not Starting After Reboot

## Status: largely automated as of 2026-05-12

The netplan stanza below is now baked into:
- `infra/packer/ubuntu-cloud-init/ubuntu-2404.pkr.hcl` — every new template clone has it on first boot
- `infra/ansible/playbooks/k8s-node-fixes.yml` — idempotent recovery if the file is missing
- Kubespray inventory enables Multus + disables `cilium_cni_exclusive`

Run the ansible playbook to restore the netplan on existing nodes instead of editing them by hand:

```bash
cd infra/ansible
ansible-playbook -i ../kubespray/inventory/inventory.ini \
  playbooks/k8s-node-fixes.yml \
  --limit k8s_cluster -u ubuntu --become \
  --start-at-task='Ensure VLAN parent interfaces are UP via netplan'
# (M76: SSH is cert-only — no --private-key; the step-ca cert is presented via ssh-config)
```

The manual steps below are kept for emergency use when ansible/SSH is broken.

## Problem

After cluster reboot, the Multus VLAN parent interfaces (`enp6s19/20/21` on every node) do not come up automatically, causing Multus networking to fail. The same netplan file also declares the two DHCP storage NICs `enp6s22` (Ceph/VLAN 210) and `enp6s23` (NAS/VLAN 209) — `enp6s23` in particular MUST be declared before the NIC is added to the VM or `networkd-wait-online` hangs boot (2026-05-29 incident).

**Symptoms:**
- Home Assistant cannot reach Hue devices (VLAN 204 - IoT)
- Alexa reports "device is not responding"
- Ping to VLAN gateways fails from pods with Multus networks
- `ip link show` shows interfaces as `state DOWN`

## Root Cause

The VLAN parent interfaces are not configured in Netplan, so they remain DOWN after system boot. Multus macvlan CNI requires these parent interfaces to be UP to create virtual interfaces for pods.

## Manual recovery (emergency only)

Prefer running the ansible playbook (above) — it writes the full, current file.
Hand-write the netplan only if ansible/SSH is broken, and reproduce **all five**
interfaces. A 3-NIC file is incomplete: it omits the Ceph (`enp6s22`) and NAS
(`enp6s23`) storage NICs, and a missing `enp6s23` declaration hangs boot on
`networkd-wait-online` (2026-05-29 incident).

Create the netplan file on the affected node and apply:

```bash
sudo tee /etc/netplan/51-vlan-interfaces.yaml > /dev/null <<'NETPLAN'
network:
  version: 2
  ethernets:
    # Multus parent NICs (VLANs 202/204/205) — Multus brings them up per-pod
    # via macvlan, so they just need to be declared so netplan doesn't fail.
    enp6s19:
      optional: true
      dhcp4: no
      dhcp6: no
    enp6s20:
      optional: true
      dhcp4: no
      dhcp6: no
    enp6s21:
      optional: true
      dhcp4: no
      dhcp6: no
    # Ceph storage NIC (VLAN 210). dhcp4-overrides is critical — without it
    # UniFi's DHCP pushes a default route + DNS host routes via the Ceph
    # gateway and breaks routing (2026-05-18 incident). L2-only to the mon.
    enp6s22:
      optional: true
      dhcp4: yes
      dhcp4-overrides:
        use-routes: no
        use-dns: no
      dhcp6: no
      mtu: 9000
    # NAS storage NIC (VLAN 209). MUST be declared (optional) BEFORE the NIC
    # is added to the VM, else networkd-wait-online hangs boot on the
    # unconfigured interface (2026-05-29 incident). Same L2-only rationale.
    enp6s23:
      optional: true
      dhcp4: yes
      dhcp4-overrides:
        use-routes: no
        use-dns: no
      dhcp6: no
      mtu: 9000
NETPLAN

sudo chmod 600 /etc/netplan/51-vlan-interfaces.yaml
sudo netplan apply
```

### Verify interfaces are UP

```bash
ip link show enp6s19 enp6s20 enp6s21 | grep "state UP"
```

### Verify pod connectivity

```bash
# Test from Home Assistant pod
kubectl exec -n home-automation deployment/home-assistant -- \
  sh -c "ping -c 2 10.10.202.1 && ping -c 2 10.10.204.1 && ping -c 2 10.10.205.1"
```

## Manual Workaround (Temporary)

If you need to bring interfaces up immediately without rebooting and
without writing the netplan file:

```bash
# All current K8s nodes use enp6s19/20/21 (post-Packer-9001 rebuild).
sudo ip link set enp6s19 up
sudo ip link set enp6s20 up
sudo ip link set enp6s21 up
```

## Prevention

The Netplan configuration ensures interfaces auto-start on boot. Verify after any future reboots that:
1. All nodes have the Netplan config file
2. Interfaces show `state UP` after boot
3. Pod VLAN connectivity works

## Related Issues

- Multus networking fails if parent interfaces are down
- Home Assistant loses access to Hue bridge (VLAN 204)
- Alexa integration fails due to lost Hue connectivity

## References

- Multus Documentation: `/platform/kubernetes/multus/README.md`
- Network Attachment Definitions: `/platform/kubernetes/multus/network-attachment-definitions/`
