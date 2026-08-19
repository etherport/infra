# home-radio — Z-Wave + Zigbee radio bridge for Home Assistant

**Status:** ✅ Zigbee LIVE (ZHA configured 2026-08-16). ⏳ Z-Wave radio verified working but
**no server deployed** — deliberately deferred, no Z-Wave devices owned yet (§6).

`home-radio` (VM **1007**, `10.10.201.41`) exposes the two radios of a USB combo stick —
physically attached to the **PVE host** — as TCP ports, so Home Assistant can use them
without being pinned to a node.

---

## 1. Why a VM instead of USB into a k8s worker

Home Assistant runs as a **pod**. Passing the USB device into a worker node would:

- **pin HA to that node permanently** — node patching then means HA downtime, and it loses
  rescheduling entirely;
- require a device mount, **reopening the privilege drop from H46** (HA was deliberately
  de-privileged).

Instead the VM does exactly one job — present both radios over TCP — and HA stays
reschedulable and unprivileged. It also avoids **zigbee2mqtt**, which would require an MQTT
broker this estate does not run; HA's built-in **ZHA** speaks `socket://` directly.

```
stick (PVE host) → USB passthrough → VM 1007 → cp210x → /dev/zigbee + /dev/zwave
                 → ser2net :6638 / :3333 → Cilium egress allow → HA pod
```

## 2. The hardware

Silicon Labs **CP2105 dual-UART bridge**, `10c4:ea70`, serial `00C3AED7`. Two interfaces →
two radios.

⚠️ **The interface mapping is the OPPOSITE of the common HUSBZB-1 write-up.**
Verified empirically on this device 2026-08-16 by probing each port with both protocols:

| USB iface | Probe | Response | Radio |
|---|---|---|---|
| **00** | EZSP/ASH reset `1A C0 38 BC 7E` | `1a c1 02 0b 0a 52 7e` (`0xC1` = RSTACK) | **Zigbee** |
| **01** | Z-Wave GetVersion `01 03 00 15 E9` | `06 01 10 01 15 "Z-Wave 7.22"` (ACK + fw) | **Z-Wave** |

Both run at **115200**. An earlier revision assumed `00 = Z-Wave` and `zigbee = 57600`; both
were wrong. **Symptom of getting the mapping wrong:** ZHA connects over TCP, then reports
*"was not able to automatically detect serial port settings"* — which reads like a firmware
or permissions fault and sends you hunting baud rates, when in fact you are speaking EZSP at
a Z-Wave controller. **Do not change the udev mapping without re-probing.**

**Model is UNCONFIRMED.** The dual-UART signature matches a Nortek HUSBZB-1, but the Z-Wave
side reports firmware **7.22** (700-series) while a real HUSBZB-1 is 500-series. It is
definitely a working Z-Wave + Zigbee combo; the exact model is unverified. (Separately, an
**Aeotec Z-Stick 10 Pro** — Z-Wave only — is owned but missing; it is *not* this device.)

## 3. Host config (all in `infra/ansible/playbooks/home-radio.yml`)

⚠️ **The landmine:** the Ubuntu cloud image ships **no `linux-modules-extra-$(uname -r)`**, so
the `cp210x` driver is **absent**. The device enumerates in `lsusb` but **no `/dev/ttyUSB*`
appears** and the radios are simply invisible — no error anywhere. *Identical root cause to
M91's i6300esb watchdog.* It is per-kernel-version, so a kernel bump silently removes the
radios again; the playbook installs the versioned package **and** the `linux-generic` meta,
then asserts the module file exists rather than trusting apt's exit code.

Also: stable `/dev/zigbee` + `/dev/zwave` symlinks bound by **USB interface number** (ttyUSB0/1
ordering is not guaranteed across re-enumeration, and a silent swap points each controller at
the wrong radio), then `ser2net` exposing **:6638 Zigbee** and **:3333 Z-Wave**.

Run it: `ansible-vm-fleet.yml` → playbook=`home-radio`, inventory=`wind`, limit=`home-radio`.

## 4. Security posture

- **M76:** enrolled in the step-ca user CA; cert auth proven **before** the static key was
  removed; cloud-init bootstrap key verified **rejected**.
  ⚠️ Test key rejection with **`ssh -F /dev/null`** — the devbox ssh-config is cert-only and
  will silently supply the certificate, so a naive `-i key -o IdentitiesOnly=yes` test
  authenticates with the cert and looks like the key still works.
- **M77:** `policy_in=DROP` + baseline SG + ser2net allows
  (`infra/terraform/proxmox/firewall/standalone-vms.tf`). Verified: an unlisted port times out.
- **Cilium:** `home-automation` is an enforced tier; egress to `10.10.201.41/32` on :3333/:6638
  is allowlisted in `platform/kubernetes/networkpolicies/23-tier-home-automation.yaml`.

⚠️ **ser2net is a RAW, UNAUTHENTICATED serial console.** Anything that reaches those ports can
pair, unpair or actuate every device on the radio network — there is no auth layer behind it.
That is why both the PVE firewall and the Cilium policy scope it to a single /32 and two ports.

⚠️ **The firewall source is the Servers/K8s VLAN, NOT the pod CIDR.** Pod egress is SNAT'd —
verified on the wire that an HA pod's SYN arrives from node IP `10.10.201.55`. Allowing
`10.42.0.0/16` would produce a policy that looks right and blocks everything.

## 5. Zigbee (LIVE)

HA → Settings → Devices & Services → **ZHA**, radio type **EZSP**, entered manually:

| Setting | Value |
|---|---|
| Serial device path | `socket://10.10.201.41:6638` |
| Port speed | `115200` |
| Flow control | `none` |

Pairing note: Zigbee is 2.4 GHz and shares spectrum with Wi-Fi — channel overlap is the usual
cause of flaky pairing. Keep a device close to the stick for initial join; mains-powered
devices then act as routers and extend the mesh.

## 6. Z-Wave — WHEN YOU ARE READY

The radio is **live and verified** (`Z-Wave 7.22` answering on `:3333`); only the server side is
missing. Deferred deliberately 2026-08-18: no Z-Wave devices owned, so deploying a server now
would mean patching and monitoring a service with nothing on it. Nothing decays by waiting.

Unlike Zigbee, HA cannot talk to this directly — its Z-Wave integration requires a separate
**zwave-js server**. Work required (~30–45 min):

1. **Generate the network security keys FIRST** — one S0 plus three S2 keys (Unauthenticated,
   Authenticated, Access Control). SOPS-encrypt them and confirm they are in git **before
   pairing anything**.
   ⚠️ **This is the one irreversible step.** Devices are enrolled *against these keys*. Lose
   them and every Z-Wave device must be factory-reset and re-paired **by hand, physically**.
2. Deploy **zwave-js-ui** in the `home-automation` namespace — Deployment + Service + a small
   Ceph-RBD PVC for its config/device DB. Point it at `tcp://10.10.201.41:3333`.
   - The namespace **already has the egress allow** to `:3333` from the Zigbee work — no
     netpol change needed for the radio hop.
   - **Kyverno enforces:** pin a real image tag (no `:latest`) and set resource requests.
   - HA → zwave-js-ui is intra-namespace; confirm the tier's ingress rules permit it.
3. Point HA's **Z-Wave** integration at
   `ws://zwave-js-ui.home-automation.svc.cluster.local:3000`.
4. Back up the zwave-js device DB — it belongs in the velero schedule alongside the keys.

## 7. Files

| Path | What |
|---|---|
| `infra/terraform/proxmox/standalone-vms/main.tf` | VM 1007 definition (`home-radio`) |
| `infra/terraform/proxmox/firewall/standalone-vms.tf` | M77 DROP + ser2net allows |
| `infra/ansible/playbooks/home-radio.yml` | drivers, udev, ser2net |
| `platform/kubernetes/networkpolicies/23-tier-home-automation.yaml` | Cilium egress allow |

⚠️ **USB passthrough is NOT in Terraform.** The bpg provider silently no-ops the VM
`watchdog {}` block (M91), so a `usb {}` block is not trusted. Attached host-side and verified
against the live config:

```bash
qm set 1007 -usb0 host=10c4:ea70     # then a COLD start — a warm reboot is not enough
qm config 1007 | grep usb            # ALWAYS verify the live config, not the command's exit
```
