#!/usr/bin/env bash
# Resets an Intel e1000e card that has hung (incidents/2026-10-29-fuji-network-card-hang
# in the infrastructure repo). Runs every 30 s from a timer. It only acts when both are
# true for a card:
#   - the kernel logged "Detected Hardware Unit Hang" for it in the last 90 s, and
#   - its default gateway doesn't answer a ping through it.
# Then it takes the port down and up; if the card hung again within the hour, it reloads
# the driver instead. At most MAX_ACTIONS actions an hour, every decision logged.
#
# DRY_RUN=1 logs what it would do without doing it. GATEWAY overrides the gateway (for
# testing the "cut off" path with an address that never answers, like 192.0.2.1).
# Not errexit/pipefail (writeShellApplication turns them on): a failing ping or a closed
# pipe is an answer here, not an error, and must never skip a real hang.
set +o errexit +o pipefail
set -u

DRY_RUN=${DRY_RUN:-0}
MAX_ACTIONS=${MAX_ACTIONS:-3}
STATE_DIR=${STATE_DIR:-/run/e1000e-watchdog}
SYSFS_NET=${SYSFS_NET:-/sys/class/net}
mkdir -p "$STATE_DIR"

log() { logger -t e1000e-watchdog -p "daemon.${2:-notice}" -- "$1"; echo "$1"; }

do_or_say() {
  if [ "$DRY_RUN" = 1 ]; then
    log "dry run, would run: $*" warning
  else
    log "running: $*" warning
    "$@"
  fi
}

since=$(date -d '-90 sec' '+%Y-%m-%d %H:%M:%S')
now=$(date +%s)

kernel_log=$(journalctl -k --since "$since" --no-pager -q 2>/dev/null)

for dev in "$SYSFS_NET"/*; do
  iface=$(basename "$dev")
  [ "$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null)")" = e1000e ] || continue

  case "$kernel_log" in
    *"$iface: Detected Hardware Unit Hang"*) ;;
    *) continue ;;
  esac

  gw=${GATEWAY:-$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')}
  if [ -n "$gw" ] && ping -c 2 -W 2 -I "$iface" "$gw" >/dev/null 2>&1; then
    log "$iface: a hang was logged but the gateway $gw answers, leaving it alone"
    continue
  fi

  # Actions in the last hour, oldest dropped.
  touch "$STATE_DIR/actions"
  awk -v cutoff=$((now - 3600)) '$1 > cutoff' "$STATE_DIR/actions" > "$STATE_DIR/actions.new"
  mv "$STATE_DIR/actions.new" "$STATE_DIR/actions"
  count=$(wc -l < "$STATE_DIR/actions")

  if [ "$count" -ge "$MAX_ACTIONS" ]; then
    log "$iface: hung and cut off (gateway ${gw:-none}), but $count resets in the last hour already; not trying again" err
    continue
  fi

  if [ "$count" -eq 0 ]; then
    log "$iface: hung and cut off (gateway ${gw:-none}), resetting the port" warning
    do_or_say ip link set "$iface" down
    [ "$DRY_RUN" = 1 ] || sleep 2
    do_or_say ip link set "$iface" up
  else
    log "$iface: hung again (gateway ${gw:-none}), reloading the e1000e driver" warning
    do_or_say modprobe -r e1000e
    [ "$DRY_RUN" = 1 ] || sleep 2
    do_or_say modprobe e1000e
  fi
  echo "$now" >> "$STATE_DIR/actions"
done
exit 0
