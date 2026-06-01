#!/usr/bin/env bash
# Regenerate config-snapshot.md — a human-readable state backup / rebuild
# reference for the UNAS Pro (Sequoia, 10.10.209.10). Read-only: SSHes with the
# unifi-cert-sync@homelab key (decrypted from the unifi-backup SOPS secret) and
# dumps device/network/shares/users + the authoritative NFS export ACLs.
#
# Requires: sops + the homelab age key (SOPS_AGE_KEY_FILE or SOPS_AGE_KEY), ssh, python3.
# Usage:    SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt infra/unifi-devices/unas/snapshot.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repo root
HOST=root@10.10.209.10
SECRET=platform/kubernetes/unifi-backup/01-secret-ssh.sops.yaml
OUT=infra/unifi-devices/unas/config-snapshot.md
TMP=$(mktemp); RAW=$(mktemp)
trap 'rm -f "$TMP" "$RAW"' EXIT

sops -d "$SECRET" | python3 -c "import sys,yaml;sys.stdout.write(yaml.safe_load(sys.stdin)['stringData']['id_ed25519'])" > "$TMP"
chmod 600 "$TMP"
ssh -i "$TMP" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -o PreferredAuthentications=publickey -o IdentitiesOnly=yes "$HOST" \
  'echo "###DEVICE"; grep PRETTY /etc/os-release; uname -srm; hostname; echo "###NETWORK"; ip -4 addr show; ip route; echo "###EXPORTS"; exportfs -v; echo "###USERS"; getent passwd' > "$RAW"

python3 - "$RAW" > "$OUT" <<'PY'
import sys,re
secs={}; cur=None
for ln in open(sys.argv[1]).read().splitlines():
    if ln.startswith("###"): cur=ln[3:]; secs[cur]=[]; continue
    if cur is not None: secs[cur].append(ln)
def block(lines): return "```\n"+"\n".join(l for l in lines if l.strip())+"\n```"
o=["# UNAS (Sequoia) — config snapshot\n",
   "_Human-readable state backup / rebuild reference for the UNAS Pro (`10.10.209.10`, VLAN 209)._  ",
   "_Regenerate with `infra/unifi-devices/unas/snapshot.sh` (read-only SSH, key `unifi-cert-sync@homelab`)._\n",
   "## Device\n"+block(secs.get("DEVICE",[]))]
net=[l.strip() for l in secs.get("NETWORK",[]) if ("inet " in l and "127.0.0.1" not in l) or l.startswith("default")]
o.append("\n## Network\n"+block(net))
share=None; rows={}
for ln in secs.get("EXPORTS",[]):
    m=re.match(r'^(/\S+)',ln)
    if m: share=re.sub(r'.*/\.unifi-drive/','',m.group(1)).replace('/.data',''); rows.setdefault(share,[])
    elif ln.strip() and share is not None:
        h=ln.strip().split('(')[0]; rows[share].append((h, ln.strip()[len(h):].strip('()')))
o.append("\n## Shares\n```\n"+"\n".join(sorted(rows))+"\n```")
users=[l for l in secs.get("USERS",[]) if l.count(":")>=6 and (l.split(":")[2] or "x").isdigit() and 1000<=int(l.split(":")[2])<65000]
o.append("\n## NAS users (uid 1000-65000)\n```\n"+"\n".join(f"{l.split(':')[2]}  {l.split(':')[0]}" for l in sorted(users,key=lambda x:int(x.split(':')[2])))+"\n```")
o.append("\n## NFS export ACLs (authoritative — who can mount what)\n")
o.append("Rebuild-critical (UI-managed; re-apply after a factory reset).\n```")
for s in sorted(rows):
    hosts=sorted(set(h for h,_ in rows[s])); opt=rows[s][0][1] if rows[s] else ""
    o.append(f"{s}:\n  hosts: {', '.join(hosts)}\n  opts:  {opt}")
o.append("```")
print("\n".join(o))
PY
echo "wrote $OUT"
