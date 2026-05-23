#!/usr/bin/env python3
"""
Idempotent Technitium log/stat retention setter — multi-replica aware.

Logs in via /api/user/login on each replica, fetches current settings,
and only PATCHes the ones that differ from the env-declared targets.
Safe to run on a recurring schedule.

Env (all required):
  TECHNITIUM_URLS      Comma-separated list of pod URLs (one per replica),
                       e.g. "http://technitium-0.technitium-headless.dns.svc.cluster.local:5380,
                             http://technitium-1.technitium-headless.dns.svc.cluster.local:5380"
                       We must hit each pod separately because Technitium
                       cluster mode does NOT sync settings between
                       replicas (verified 2026-05-23: cluster-initialized
                       was True, but maxLogFileDays differed per pod
                       after a single /api/settings/set call).
  ADMIN_USER           Technitium admin username
  ADMIN_PASSWORD       Technitium admin password
  MAX_LOG_FILE_DAYS    e.g. "7"   (query log retention, days)
  MAX_STAT_FILE_DAYS   e.g. "90"  (stat file retention, days)

Exit codes:
  0 — every replica is now at the desired retention
  2 — invalid config (missing env)
  3 — one or more replicas failed (others may have succeeded)
"""

import json
import os
import sys
import urllib.parse
import urllib.request


def _req(method, url, data=None, timeout=15):
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def configure(base, user, pw, want_log, want_stat):
    """Bring one replica to the desired retention. Returns True on success."""
    label = base.split("//", 1)[-1].split(".", 1)[0]  # short host label
    try:
        auth = _req("POST", f"{base}/api/user/login",
                    data={"user": user, "pass": pw, "includeInfo": "false"})
        if auth.get("status") != "ok":
            print(f"[{label}] login failed: {auth}", file=sys.stderr)
            return False
        token = auth["token"]

        cur = _req("GET", f"{base}/api/settings/get?token={token}")
        if cur.get("status") != "ok":
            print(f"[{label}] settings/get failed: {cur}", file=sys.stderr)
            return False
        r = cur["response"]

        cur_log = int(r.get("maxLogFileDays", 0))
        cur_stat = int(r.get("maxStatFileDays", 0))
        if cur_log == want_log and cur_stat == want_stat:
            print(f"[{label}] already at desired retention "
                  f"(maxLogFileDays={cur_log}, maxStatFileDays={cur_stat})")
            return True

        set_url = (f"{base}/api/settings/set"
                   f"?token={token}"
                   f"&maxLogFileDays={want_log}"
                   f"&maxStatFileDays={want_stat}")
        out = _req("POST", set_url)
        if out.get("status") != "ok":
            print(f"[{label}] settings/set failed: {out}", file=sys.stderr)
            return False

        print(f"[{label}] updated  maxLogFileDays={cur_log}→{want_log}, "
              f"maxStatFileDays={cur_stat}→{want_stat}")
        return True
    except Exception as e:
        print(f"[{label}] exception: {e}", file=sys.stderr)
        return False


def main():
    urls_env = os.environ.get("TECHNITIUM_URLS", "").strip()
    if not urls_env:
        print("ERROR: TECHNITIUM_URLS env var required (comma-separated)", file=sys.stderr)
        sys.exit(2)
    urls = [u.strip().rstrip("/") for u in urls_env.split(",") if u.strip()]

    user = os.environ["ADMIN_USER"]
    pw = os.environ["ADMIN_PASSWORD"]
    want_log = int(os.environ["MAX_LOG_FILE_DAYS"])
    want_stat = int(os.environ["MAX_STAT_FILE_DAYS"])

    print(f"target retention: maxLogFileDays={want_log}, maxStatFileDays={want_stat}")
    print(f"replicas: {len(urls)}")

    failures = 0
    for base in urls:
        if not configure(base, user, pw, want_log, want_stat):
            failures += 1

    if failures:
        print(f"\n{failures}/{len(urls)} replica(s) failed", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
