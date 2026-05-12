#!/bin/bash
# One-time setup: import Ubuntu 24.04 cloud image as VM 9000 template on PVE.
#
# Packer's proxmox-clone source then clones VM 9000 each build to produce
# the customized VM 9001 template.
#
# Run on PVE host as root (e.g. via `ssh -t graham@pve 'sudo bash -s' < setup-cloud-base.sh`).
# Re-running is safe: existing VM 9000 is destroyed first.

set -euo pipefail

BASE_VMID="${BASE_VMID:-9000}"
BASE_NAME="${BASE_NAME:-ubuntu-2404-cloud-base}"
STORAGE="${STORAGE:-local-zfs}"
IMG_PATH="${IMG_PATH:-/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-201}"

if [ ! -f "$IMG_PATH" ]; then
  echo "Cloud image not found at $IMG_PATH"
  echo "Download with:"
  echo "  wget -O $IMG_PATH https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  exit 1
fi

echo ">>> Checking for existing VM $BASE_VMID..."
if qm status "$BASE_VMID" &>/dev/null; then
  echo ">>> VM $BASE_VMID exists. Stopping and destroying for clean re-import."
  qm stop "$BASE_VMID" &>/dev/null || true
  sleep 2
  qm destroy "$BASE_VMID" --purge --destroy-unreferenced-disks 1
fi

echo ">>> Creating VM $BASE_VMID ($BASE_NAME)..."
qm create "$BASE_VMID" \
  --name "$BASE_NAME" \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --efidisk0 "$STORAGE:0,efitype=4m,pre-enrolled-keys=0" \
  --scsihw virtio-scsi-pci \
  --net0 "virtio,bridge=$BRIDGE,tag=$VLAN_TAG" \
  --serial0 socket \
  --vga serial0 \
  --agent enabled=1 \
  --ostype l26 \
  --tags "template;ubuntu;cloud-init;base"

echo ">>> Importing cloud image to $STORAGE..."
qm importdisk "$BASE_VMID" "$IMG_PATH" "$STORAGE" --format raw

echo ">>> Attaching imported disk as scsi0..."
qm set "$BASE_VMID" --scsi0 "$STORAGE:vm-$BASE_VMID-disk-1,discard=on,ssd=1"

echo ">>> Adding cloud-init drive..."
qm set "$BASE_VMID" --ide2 "$STORAGE:cloudinit"

echo ">>> Setting boot order (disk first)..."
qm set "$BASE_VMID" --boot "order=scsi0;ide2;net0"

echo ">>> Resizing disk to 10G..."
qm resize "$BASE_VMID" scsi0 10G

echo ">>> Setting default cloud-init user (ubuntu)..."
qm set "$BASE_VMID" --ciuser ubuntu

echo ">>> Converting to template..."
qm template "$BASE_VMID"

echo
echo "=== Done! VM $BASE_VMID is now a template. ==="
qm config "$BASE_VMID" | head -25
