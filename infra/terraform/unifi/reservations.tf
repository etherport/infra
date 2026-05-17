# UniFi static DHCP reservations.
#
# Two groups:
#  1. Imported: existing reservations from the live UDM (10 entries).
#  2. New: K8s + standalone-VM infra hosts that have static cloud-init
#     IPs today but no DHCP anchor — adding here so a renaming/swapped
#     MAC won't put their IP into the floating DHCP scope by accident.
#
# Schema: `unifi_user` in paultyng/unifi. Required: mac. Optional: name,
# fixed_ip, network_id, note.
#
# Note: PVE (10.10.200.41) deferred — physical host, MAC requires SSH
# lookup and wasn't reachable when this file was authored. Add later.

# =============================================================================
# Imported reservations (10) — existing in UDM today.
# =============================================================================

resource "unifi_user" "hue1" {
  mac        = "00:17:88:7a:1f:3f"
  name       = "hue1"
  fixed_ip   = "10.10.204.51"
  network_id = unifi_network.iot.id
  note       = "Philips Hue bridge 1 (Cabin) — IoT VLAN with cross-VLAN routing"
}

import {
  to = unifi_user.hue1
  id = "60915d81f2a1050260a93ad6"
}

resource "unifi_user" "hue2" {
  mac        = "ec:b5:fa:34:ab:ef"
  name       = "hue2"
  fixed_ip   = "10.10.204.52"
  network_id = unifi_network.iot.id
  note       = "Philips Hue bridge 2 (Cabin) — IoT VLAN with cross-VLAN routing"
}

import {
  to = unifi_user.hue2
  id = "60915d5df2a1050260a935a4"
}

# Graham's original wired MBP MAC (pre-WiFi-only era). Kept for reference.
resource "unifi_user" "mac_graham_wired" {
  mac        = "00:30:93:12:0c:f9"
  name       = "mac-graham-wired"
  fixed_ip   = "10.10.202.100"
  network_id = unifi_network.clients.id
  note       = "Graham's MBP — wired interface (legacy)"
}

import {
  to = unifi_user.mac_graham_wired
  id = "609199a48af751055c6f7d15"
}

resource "unifi_user" "canon" {
  mac        = "f4:a9:97:ca:ca:a4"
  name       = "Canon MF743C"
  fixed_ip   = "10.10.202.50"
  network_id = unifi_network.clients.id
  note       = "Canon MF743C network printer"
}

import {
  to = unifi_user.canon
  id = "6099a2492d6b290436a8229f"
}

resource "unifi_user" "mac_graham" {
  mac      = "f0:2f:4b:09:b9:b4"
  name     = "Grahams-MBP-WiFi"
  fixed_ip = "10.10.202.110"
  note     = "Graham's MacBook Pro (WiFi)"
}

import {
  to = unifi_user.mac_graham
  id = "63f2e463ef3a475d6a8eb61b"
}

resource "unifi_user" "mac_workroom" {
  mac      = "2c:82:17:db:17:83"
  name     = "Workroom Mac Mini"
  fixed_ip = "10.10.202.101"
  note     = "Workroom Mac Mini"
}

import {
  to = unifi_user.mac_workroom
  id = "64a9fbfb6adaed18e78f29d4"
}

resource "unifi_user" "ups1" {
  mac      = "28:29:86:36:d6:30"
  name     = "UPS1"
  fixed_ip = "10.10.200.10"
  note     = "UPS 1 (mgmt VLAN; web UI via Traefik at ups1.wind.etherport.net)"
}

import {
  to = unifi_user.ups1
  id = "67f8e8cda53ac25b1e041572"
}

resource "unifi_user" "ups2" {
  mac      = "00:c0:b7:9f:b5:dd"
  name     = "UPS2"
  fixed_ip = "10.10.200.11"
  note     = "UPS 2 (mgmt VLAN; web UI via Traefik at ups2.wind.etherport.net)"
}

import {
  to = unifi_user.ups2
  id = "6808be9a044c620ffe187129"
}

resource "unifi_user" "pdu1" {
  mac      = "28:29:86:1a:60:4f"
  name     = "PDU1"
  fixed_ip = "10.10.200.15"
  note     = "PDU 1 (mgmt VLAN; web UI via Traefik at pdu1.wind.etherport.net)"
}

import {
  to = unifi_user.pdu1
  id = "6808be9a044c620ffe18712a"
}

resource "unifi_user" "pdu2" {
  mac      = "00:c0:b7:e3:fe:da"
  name     = "PDU2"
  fixed_ip = "10.10.200.16"
  note     = "PDU 2 (mgmt VLAN; web UI via Traefik at pdu2.wind.etherport.net)"
}

import {
  to = unifi_user.pdu2
  id = "67f8e8cda53ac25b1e041573"
}

# =============================================================================
# New reservations (11) — infra hosts with cloud-init static IPs but no
# DHCP anchor. Add MAC-bound reservations so they're protected from DHCP
# pool conflicts. MACs sourced from proxmox TF state (k8s-vms +
# standalone-vms) on 2026-05-17.
#
# PVE (10.10.200.41) deferred — physical host, will add after MAC lookup.
# =============================================================================

resource "unifi_user" "k8s_cp1" {
  mac      = "bc:24:11:b1:c9:45"
  name     = "k8s-cp1"
  fixed_ip = "10.10.201.50"
  note     = "Kubernetes control plane 1 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_cp2" {
  mac      = "bc:24:11:1b:17:14"
  name     = "k8s-cp2"
  fixed_ip = "10.10.201.51"
  note     = "Kubernetes control plane 2 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_cp3" {
  mac      = "bc:24:11:3d:fd:d8"
  name     = "k8s-cp3"
  fixed_ip = "10.10.201.52"
  note     = "Kubernetes control plane 3 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_w1" {
  mac      = "bc:24:11:7a:47:f2"
  name     = "k8s-w1"
  fixed_ip = "10.10.201.53"
  note     = "Kubernetes worker 1 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_w2" {
  mac      = "bc:24:11:48:e4:57"
  name     = "k8s-w2"
  fixed_ip = "10.10.201.54"
  note     = "Kubernetes worker 2 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_w3" {
  mac      = "bc:24:11:df:b9:44"
  name     = "k8s-w3"
  fixed_ip = "10.10.201.55"
  note     = "Kubernetes worker 3 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_w4" {
  mac      = "bc:24:11:b8:d4:f8"
  name     = "k8s-w4"
  fixed_ip = "10.10.201.56"
  note     = "Kubernetes worker 4 (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "k8s_gpu1" {
  mac      = "bc:24:11:04:fb:3f"
  name     = "k8s-gpu1"
  fixed_ip = "10.10.201.60"
  note     = "Kubernetes GPU worker (managed by TF; see proxmox/k8s-vms)"
}

resource "unifi_user" "dns_fallback" {
  mac      = "bc:24:11:4a:2c:36"
  name     = "dns-fallback"
  fixed_ip = "10.10.201.6"
  note     = "Technitium DNS fallback (managed by TF; see proxmox/standalone-vms)"
}

resource "unifi_user" "vpn_local" {
  mac      = "bc:24:11:d4:cd:c1"
  name     = "vpn-local"
  fixed_ip = "10.10.201.15"
  note     = "WireGuard local site VM (managed by TF; see proxmox/standalone-vms)"
}

resource "unifi_user" "gh_runner" {
  mac      = "bc:24:11:39:74:c7"
  name     = "gh-runner"
  fixed_ip = "10.10.201.30"
  note     = "GitHub Actions self-hosted runner (managed by TF; see proxmox/standalone-vms)"
}
