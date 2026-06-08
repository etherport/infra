#!/usr/bin/env python3
"""
Sync 1Password (the master) -> SOPS-encrypted homelab operational secret.

1Password stays the source of truth. This reads each op:// reference in the
manifest via `op read` and writes infra/ansible/playbooks/secrets/homelab-ops.sops.yaml
(SOPS-encrypted with the Homelab age recipient). The dev box + CI then consume
that file headlessly with the age key — no `op`, no per-operation unlocks.

Run it WHERE 1PASSWORD IS UNLOCKED (your laptop) — on rotation or when you add a
secret to the manifest. Requires: op (signed in), sops.

    python3 scripts/sync-secrets.py
"""
import os
import subprocess
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "infra/ansible/playbooks/secrets/homelab-ops.manifest.yaml")
OUT = os.path.join(ROOT, "infra/ansible/playbooks/secrets/homelab-ops.sops.yaml")


def op_read(ref: str) -> str:
    r = subprocess.run(["op", "read", ref], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"op read failed for {ref!r}: {r.stderr.strip()}")
    return r.stdout


def main() -> None:
    manifest = yaml.safe_load(open(MANIFEST))
    out = {}
    for key, ref in manifest.items():
        if not isinstance(ref, str) or not ref.startswith("op://"):
            continue
        val = op_read(ref)
        # Multi-line (SSH key) -> keep verbatim with one trailing newline (yaml
        # emits a block scalar). Single-line (passwords/tokens) -> strip the
        # trailing newline `op` appends.
        if val.count("\n") > 1:
            out[key] = val.rstrip("\n") + "\n"
        else:
            out[key] = val.rstrip("\n")
        print(f"  {key}: {len(out[key])} chars")

    # Write plaintext to the final path (so SOPS's path-based creation rule
    # picks the right age recipient), then encrypt IN PLACE. On any failure,
    # delete the file so plaintext is never left on disk / committed.
    with open(OUT, "w") as f:
        yaml.safe_dump(out, f, default_flow_style=False, sort_keys=True)
    try:
        subprocess.run(["sops", "-e", "-i", OUT], check=True)
    except Exception:
        os.unlink(OUT)
        raise
    print(f"Synced {len(out)} secrets from 1Password -> {OUT}")
    print("Review the diff and commit.")


if __name__ == "__main__":
    main()
