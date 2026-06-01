# UNAS (Sequoia) — config snapshot

_Human-readable state backup / rebuild reference for the UNAS Pro (`10.10.209.10`, VLAN 209)._  
_Regenerate with `infra/unifi-devices/unas/snapshot.sh` (read-only SSH, key `unifi-cert-sync@homelab`)._

## Device
```
PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
Linux 5.10.216-alpine-unas aarch64
Sequoia
```

## Network
```
inet 10.10.209.10/24 brd 10.10.209.255 scope global dynamic lag0
default via 10.10.209.1 dev lag0 proto dhcp src 10.10.209.10 metric 1024
```

## Shares
```
Archive
Backups
Content
Graham
Mark
Media
Proxmox
Scans
Temp
```

## NAS users (uid 1000-65000)
```
1000  graham
1001  aws
1002  plex
1003  scan
1004  mark
1005  uishd-aj02h6nb015knak4q2sfhlif9k
```

## NFS export ACLs (authoritative — who can mount what)

Rebuild-critical (UI-managed; re-apply after a factory reset).
```
Archive:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Backups:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  rw,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,rw,secure,root_squash,all_squash
Content:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Graham:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Mark:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Media:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Proxmox:
  hosts: 10.10.200.41, 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Scans:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
Temp:
  hosts: 10.10.201.50, 10.10.201.51, 10.10.201.52, 10.10.201.53, 10.10.201.54, 10.10.201.55, 10.10.201.56, 10.10.201.57, 10.10.201.58, 10.10.201.59, 10.10.201.60, 10.10.209.100, 10.10.209.101, 10.10.209.102, 10.10.209.103, 10.10.209.104
  opts:  ro,wdelay,crossmnt,root_squash,all_squash,no_subtree_check,anonuid=977,anongid=988,sec=sys,ro,secure,root_squash,all_squash
```
