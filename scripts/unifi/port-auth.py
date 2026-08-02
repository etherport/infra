#!/usr/bin/env python3
"""
port-auth.py — idempotent UniFi switch-port MAB manager (#18 phase 2).

⚠️ NOT USABLE ON THE CURRENT OUTDOOR SWITCHES (verified 2026-08-02). The
Driveway/Access Road USF5P (Flex) have NO 802.1X support, and the Chapel USL8LP
(Lite) reports dot1x but stays stuck at force_auth (mac_based never enforces).
The controller ACCEPTS the profile assignment but the switch silently drops it
(UI: "options that will not be applied"). This script + mechanism are SOUND and
kept for when an 802.1X-CAPABLE switch (USW-Pro / -Enterprise / standard USW) is
installed outdoors. Until then it is a no-op on this hardware. Details:
docs/planning/dot1x-mab-design-2026-07-29.md.

HOW MAB actually works on this controller (verified 2026-08-01):
  Per-port overrides CANNOT carry auth config on profiled ports — the controller
  silently strips BOTH `port_security_*` AND `dot1x_ctrl` from any override that
  has a `portconf_id` (both were verified stripped). Auth lives in the PORT
  PROFILE: a dedicated "Cameras MAB" portconf (clone of "UniFi Devices" +
  `dot1x_ctrl: mac_based`) + the global `global_switch.dot1x_portctrl_enabled`
  flag + a RADIUS account per MAC (username=password=lowercase-colon MAC).
  Proven end-to-end: PoE-cut a camera, fresh link-up authenticated via RADIUS.

MODEL (profile swap):
  - `mab`   : port's portconf -> the "Cameras MAB" profile + RADIUS accounts for
              its MACs. VLAN identical (the MAB profile is a clone of the base).
  - `open`  : port's portconf -> the base "UniFi Devices" profile (ROLLBACK).

SAFETY:
  - Refuses to modify any port that is an UPLINK (another device uplinks through
    it, or it is this switch's own uplink) — MAB on an uplink breaks everything
    downstream.
  - --dry-run is the DEFAULT. --apply is required to write. After apply it
    re-reads and warns if a targeted port went DOWN (a real device that failed
    auth) so you can roll back fast.
  - The UDM rate-limiter trips under rapid calls; the script paces writes.

AUTH: UNIFI_API_KEY env, else `sops -d` the ops bundle key `udm_api_key`.

Usage:
  ./port-auth.py                 # dry-run: show the diff vs desired-state
  ./port-auth.py --apply         # apply (writes ports + RADIUS accounts)
  ./port-auth.py --rollback SW   # force every port on switch SW back to `open`
"""
import argparse, json, os, ssl, subprocess, sys, time, urllib.request, urllib.error

UDM = "https://10.10.200.1"
BASE = UDM + "/proxy/network/api/s/default"
HERE = os.path.dirname(os.path.abspath(__file__))
DESIRED = os.path.join(HERE, "port-auth.yaml")
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE


def api_key():
    k = os.environ.get("UNIFI_API_KEY")
    if k:
        return k
    bundle = os.path.join(HERE, "..", "..", "infra", "ansible", "playbooks",
                          "secrets", "homelab-ops.sops.yaml")
    out = subprocess.run(["sops", "-d", bundle], capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("udm_api_key:"):
            return line.split(":", 1)[1].strip().strip('"')
    sys.exit("no udm_api_key in the ops bundle and UNIFI_API_KEY unset")


def req(key, path, method="GET", body=None):
    r = urllib.request.Request(BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"X-API-KEY": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, context=CTX, timeout=25) as resp:
        return json.loads(resp.read() or "{}")


def load_desired():
    # minimal YAML reader (no PyYAML dep): switches -> ports -> {mode, macs}
    import yaml  # devbox venvs have it; fall back below if not
    with open(DESIRED) as f:
        return yaml.safe_load(f)


def uplink_ports(devices):
    """Set of (switch_name, port_idx) that are uplinks — NEVER touch these."""
    by_mac = {d["mac"]: d.get("name") for d in devices}
    up = set()
    for d in devices:
        ul = d.get("uplink") or {}
        # this device's own uplink port (local)
        if ul.get("num_port"):
            up.add((d.get("name"), ul["num_port"]))
        # the remote port another device plugs INTO
        rmac, rport = ul.get("uplink_mac"), ul.get("uplink_remote_port")
        if rmac in by_mac and rport:
            up.add((by_mac[rmac], rport))
    return up


def ensure_radius_accounts(key, macs, accounts, dry):
    """MAB: one RADIUS account per MAC (name=password=MAC, no spaces/colons per fork)."""
    have = {a.get("name", "").lower() for a in accounts}
    made = []
    for mac in macs:
        name = mac.lower()
        if name in have:
            continue
        made.append(mac)
        if not dry:
            req(key, "/rest/account", "POST",
                {"name": name, "x_password": name,
                 "tunnel_type": 13, "tunnel_medium_type": 6, "vlan": ""})
            time.sleep(0.4)
    return made


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write changes (default is dry-run)")
    ap.add_argument("--rollback", metavar="SWITCH", help="force all desired ports on SWITCH back to open")
    args = ap.parse_args()
    dry = not args.apply

    key = api_key()
    desired = load_desired()
    devices = req(key, "/stat/device")["data"]
    accounts = req(key, "/rest/account").get("data", [])
    by_name = {d.get("name"): d for d in devices if d.get("type") == "usw"}
    uplinks = uplink_ports(devices)

    # resolve the two profiles + the global dot1x flag
    pcs = req(key, "/rest/portconf")["data"]
    prof = {p.get("name"): p["_id"] for p in pcs}
    MAB_P, BASE_P = prof.get("Cameras MAB"), prof.get("UniFi Devices")
    if not MAB_P or not BASE_P:
        sys.exit("missing 'Cameras MAB' or 'UniFi Devices' portconf — see README bootstrap")
    gs = [x for x in req(key, "/get/setting")["data"] if x.get("key") == "global_switch"][0]
    if not gs.get("dot1x_portctrl_enabled"):
        print("!! global_switch.dot1x_portctrl_enabled is FALSE — MAB profiles will not enforce"
              " (enable it via the console or /set/setting/global_switch)")

    all_macs, plans = set(), []
    for sw in desired.get("switches", []):
        name = sw["name"]
        dev = by_name.get(name)
        if not dev:
            print(f"!! switch '{name}' not found — skipping"); continue
        ov = {o["port_idx"]: o for o in dev.get("port_overrides", [])}
        pt = {p["port_idx"]: p for p in dev.get("port_table", [])}
        for port in sw.get("ports", []):
            idx = port["port"]
            mode = "open" if args.rollback == name else port.get("mode", "open")
            macs = [m.lower() for m in port.get("macs", [])]
            if (name, idx) in uplinks:
                print(f"!! REFUSING {name} p{idx}: it is an UPLINK — skipped"); continue
            want_pc = MAB_P if mode == "mab" else BASE_P
            cur_pc = ov.get(idx, {}).get("portconf_id")
            if mode == "mab":
                all_macs.update(macs)
            if cur_pc != want_pc:
                plans.append((name, dev["_id"], idx, ov.get(idx, {}), want_pc,
                              pt.get(idx, {}).get("up"), mode, macs))

    # RADIUS accounts first (a MAB port with no account = deauth)
    made = ensure_radius_accounts(key, sorted(all_macs), accounts, dry)
    print(f"RADIUS accounts to create: {made or 'none (all present)'}")

    if not plans:
        print("all targeted ports already in desired state — no port changes.")
        return
    print(f"\n{'DRY-RUN — ' if dry else ''}port changes:")
    # group by device so we PUT the full merged override array once per switch
    by_dev = {}
    prof_name = {v: k for k, v in prof.items()}
    for name, did, idx, cur, pc, up, mode, macs in plans:
        print(f"  {name:24} p{idx:<2} profile -> {prof_name.get(pc, pc):16} (mode={mode}, currently up={up})")
        by_dev.setdefault((name, did), []).append((idx, pc))
    if dry:
        print("\n(dry-run) re-run with --apply to write.")
        return

    for (name, did), changes in by_dev.items():
        dev = by_name[name]
        ov = {o["port_idx"]: o for o in dev.get("port_overrides", [])}
        for idx, pc in changes:
            o = ov.get(idx, {"port_idx": idx, "name": f"Port {idx}"})
            o["portconf_id"] = pc
            ov[idx] = o
        req(key, f"/rest/device/{did}", "PUT",
            {"port_overrides": sorted(ov.values(), key=lambda x: x["port_idx"])})
        print(f"  applied {name}: {[c[0] for c in changes]}")
        time.sleep(1.0)

    print("\nverifying targeted ports stayed UP (a DOWN port = device failed auth → roll back)...")
    time.sleep(20)
    devices2 = req(key, "/stat/device")["data"]
    by_name2 = {d.get("name"): d for d in devices2 if d.get("type") == "usw"}
    for name, did, idx, cur, pc, was_up, mode, macs in plans:
        now = {p["port_idx"]: p for p in by_name2[name].get("port_table", [])}.get(idx, {})
        if was_up and not now.get("up"):
            print(f"  ⚠️  {name} p{idx} went DOWN after {mode} — device failed auth. "
                  f"Roll back: ./port-auth.py --rollback '{name}' --apply")
        else:
            print(f"  ok  {name} p{idx} up={now.get('up')}")


if __name__ == "__main__":
    main()
