#!/bin/bash
# Mini health heartbeat — a frequent, lightweight check that the mini's backup machinery is
# operational, pushed to Pushgateway as mini_health_* so the cluster status-report email +
# alerts can confirm "the mini is up and able to back up". The HEARTBEAT itself is the key
# signal: if mini_health_last_check_timestamp_seconds stops advancing, the mini is down OR can't
# reach the monitoring VIP (exactly today's outage) → an absence/staleness alert fires.
#
# Runs every 15 min via net.wind.mini-health (StartInterval). Read-only + cheap: launchctl /
# mount / df / an rsync-stat NAS probe — no FDA needed (so it reports even when FDA-gated jobs
# can't run). Per-component gauges say WHICH thing is unhealthy; mini_health_up is the rollup.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSHGATEWAY="${PUSHGATEWAY:-https://pushgateway.wind.etherport.net}"
# shellcheck source=mini-common.sh
source "${HERE}/mini-common.sh"   # nas_readable
now="$(date +%s)"

# 1. Expected LaunchAgents loaded (a backup silently won't run if its agent got unloaded).
EXPECT=(net.wind.mount-nas net.wind.alloy net.wind.photos-export net.wind.icloud-dav net.wind.messages-backup net.wind.icloud-files)
loaded=0
for a in "${EXPECT[@]}"; do launchctl print "gui/$(id -u)/${a}" >/dev/null 2>&1 && loaded=$((loaded+1)); done
agents_ok=$([ "${loaded}" -eq "${#EXPECT[@]}" ] && echo 1 || echo 0)

# 2. NAS shares mounted + readable (backups fail without these).
nas_ok=1
for v in /Volumes/Backups /Volumes/Personal-Drive; do nas_readable "$v" || nas_ok=0; done

# 3. SMB tuning actually installed where the kernel reads it.
nsmb_ok=$(cmp -s "${HERE}/nsmb.conf" /etc/nsmb.conf 2>/dev/null && echo 1 || echo 0)

# 4. Mini local free disk (staging needs headroom).
disk_free="$(df -k / 2>/dev/null | awk 'NR==2{print $4*1024}')"; [ -n "${disk_free}" ] || disk_free=0

# Rollup: the things that would BLOCK a backup.
up=$([ "${agents_ok}" = 1 ] && [ "${nas_ok}" = 1 ] && echo 1 || echo 0)

body="# TYPE mini_health_up gauge
mini_health_up ${up}
# TYPE mini_health_last_check_timestamp_seconds gauge
mini_health_last_check_timestamp_seconds ${now}
# TYPE mini_health_check gauge
mini_health_check{check=\"agents_loaded\"} ${agents_ok}
mini_health_check{check=\"nas_readable\"} ${nas_ok}
mini_health_check{check=\"nsmb_applied\"} ${nsmb_ok}
# TYPE mini_health_agents_loaded gauge
mini_health_agents_loaded ${loaded}
# TYPE mini_health_agents_expected gauge
mini_health_agents_expected ${#EXPECT[@]}
# TYPE mini_health_disk_free_bytes gauge
mini_health_disk_free_bytes ${disk_free}
"
if curl -fsS --max-time 10 --data-binary "${body}" "${PUSHGATEWAY}/metrics/job/mini_health/instance/mini" >/dev/null 2>&1; then
  echo "$(date '+%F %T') mini-health: pushed (up=${up} agents=${loaded}/${#EXPECT[@]} nas=${nas_ok} nsmb=${nsmb_ok} free=$(( disk_free/1024/1024/1024 ))G)"
else
  echo "$(date '+%F %T') mini-health: push FAILED (mini can't reach ${PUSHGATEWAY} — VIP/route?)"
fi
