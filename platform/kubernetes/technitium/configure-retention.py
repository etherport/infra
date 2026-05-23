#!/usr/bin/env python3
"""
Idempotent Technitium log/stat retention setter.

Logs in via /api/user/login, fetches current settings, and only
PATCHes the ones that differ from the env-declared targets. Safe to
run on a recurring schedule.

Env (all required):
  TECHNITIUM_URL       e.g. http://technitium-headless.dns.svc.cluster.local:5380
  ADMIN_USER           Technitium admin username
  ADMIN_PASSWORD       Technitium admin password
  MAX_LOG_FILE_DAYS    e.g. "7"   (query log retention, days)
  MAX_STAT_FILE_DAYS   e.g. "90"  (stat file retention, days)

The headless Service round-robins across all replicas; we issue the
setting against whichever replica answers. Technitium replicates
settings to peers automatically once we trigger config sync.
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


def main():
    base = os.environ["TECHNITIUM_URL"].rstrip("/")
    user = os.environ["ADMIN_USER"]
    pw = os.environ["ADMIN_PASSWORD"]
    want_log = int(os.environ["MAX_LOG_FILE_DAYS"])
    want_stat = int(os.environ["MAX_STAT_FILE_DAYS"])

    # Login
    login_url = f"{base}/api/user/login"
    auth = _req("POST", login_url, data={"user": user, "pass": pw,
                                         "includeInfo": "false"})
    if auth.get("status") != "ok":
        print(f"login failed: {auth}", file=sys.stderr)
        sys.exit(2)
    token = auth["token"]

    # Get current settings
    get_url = f"{base}/api/settings/get?token={token}"
    cur = _req("GET", get_url)
    if cur.get("status") != "ok":
        print(f"settings/get failed: {cur}", file=sys.stderr)
        sys.exit(2)
    r = cur["response"]

    cur_log = int(r.get("maxLogFileDays", 0))
    cur_stat = int(r.get("maxStatFileDays", 0))
    print(f"current:  maxLogFileDays={cur_log}, maxStatFileDays={cur_stat}")
    print(f"desired:  maxLogFileDays={want_log}, maxStatFileDays={want_stat}")

    if cur_log == want_log and cur_stat == want_stat:
        print("no changes — already at desired retention")
        return

    # The Technitium API's settings/set takes all keys; missing keys
    # default. To avoid clobbering anything we didn't intend, we
    # explicitly set only the two retention fields and let the server
    # preserve everything else (it does — only the supplied keys are
    # mutated).
    set_url = (f"{base}/api/settings/set"
               f"?token={token}"
               f"&maxLogFileDays={want_log}"
               f"&maxStatFileDays={want_stat}")
    out = _req("POST", set_url)
    if out.get("status") != "ok":
        print(f"settings/set failed: {out}", file=sys.stderr)
        sys.exit(2)
    print(f"settings updated: maxLogFileDays={want_log}, maxStatFileDays={want_stat}")


if __name__ == "__main__":
    main()
