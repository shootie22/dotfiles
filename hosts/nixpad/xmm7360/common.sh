XMM7360_IFACE="${XMM7360_IFACE:-wwan0}"
XMM7360_WIFI_IFACE="${XMM7360_WIFI_IFACE:-wlp3s0}"
XMM7360_SERVICE="${XMM7360_SERVICE:-xmm7360-connect.service}"
XMM7360_DNS_KEY="${XMM7360_DNS_KEY:-xmm7360}"
XMM7360_PING_TARGET="${XMM7360_PING_TARGET:-1.1.1.1}"
XMM7360_WAIT_SECONDS="${XMM7360_WAIT_SECONDS:-45}"
XMM7360_PCI_ID="${XMM7360_PCI_ID:-8086:7360}"
XMM7360_DNS_SERVERS="${XMM7360_DNS_SERVERS:-213.154.124.1 193.231.252.1}"
XMM7360_HARD_RESET_SETTLE_SECONDS="${XMM7360_HARD_RESET_SETTLE_SECONDS:-15}"
XMM7360_ACPI_BOOT_WAIT_SECONDS="${XMM7360_ACPI_BOOT_WAIT_SECONDS:-45}"
XMM7360_RPC_WAIT_SECONDS="${XMM7360_RPC_WAIT_SECONDS:-30}"
XMM7360_ACPI_RESET_METHOD="${XMM7360_ACPI_RESET_METHOD:-\\_SB.PCI0.GPP7.L850._RST}"

xmm_log() {
  printf '%s\n' "$*"
}

xmm_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

xmm_spinner_wait() {
  local pid="$1"
  local message="$2"
  local frame
  local rc

  printf '%s ' "$message"
  while kill -0 "$pid" 2>/dev/null; do
    for frame in '-' '\' '|' '/'; do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      printf '\b%s' "$frame"
      sleep 0.15
    done
  done

  set +e
  wait "$pid"
  rc=$?
  set -e
  printf '\b'
  return "$rc"
}

xmm_public_location() {
  local json
  local ip
  local city
  local country

  json="$(curl -4 -fsS --max-time 10 https://ipinfo.io/json 2>/dev/null)" || return 1
  ip="$(printf '%s\n' "$json" | jq -r '.ip // empty')"
  city="$(printf '%s\n' "$json" | jq -r '.city // empty')"
  country="$(printf '%s\n' "$json" | jq -r '.country // empty')"

  if [ -z "$ip" ]; then
    return 1
  fi

  if [ -n "$city" ] && [ -n "$country" ]; then
    printf 'IP: %s (%s, %s)\n' "$ip" "$city" "$country"
  elif [ -n "$country" ]; then
    printf 'IP: %s (%s)\n' "$ip" "$country"
  else
    printf 'IP: %s\n' "$ip"
  fi
}

xmm_print_public_location() {
  if ! xmm_public_location; then
    echo "Public IP lookup failed."
  fi
}

xmm_wwan_ip() {
  ip -4 -o addr show dev "$XMM7360_IFACE" scope global 2>/dev/null \
    | awk '{ split($4, a, "/"); print a[1]; exit }'
}

xmm_cleanup_routes() {
  local ip_addr

  ip route del default dev "$XMM7360_IFACE" 2>/dev/null || true
  ip_addr="$(xmm_wwan_ip || true)"
  if [ -n "$ip_addr" ]; then
    ip route del default via "$ip_addr" dev "$XMM7360_IFACE" 2>/dev/null || true
  fi
}

xmm_cleanup_dns() {
  resolvconf -d "$XMM7360_DNS_KEY" 2>/dev/null || true
}

xmm_cleanup_networkmanager() {
  nmcli connection delete "$XMM7360_DNS_KEY" 2>/dev/null || true
}

xmm_stop_service() {
  xmm_log "Stopping $XMM7360_SERVICE."
  timeout 20s systemctl stop "$XMM7360_SERVICE" 2>/dev/null || true
  timeout 10s systemctl kill --kill-who=all "$XMM7360_SERVICE" 2>/dev/null || true
  xmm_log "Killing leftover modem connector processes."
  pkill -f 'xmm7360-connect|open_xdatachannel.py' 2>/dev/null || true
}

xmm_unload_module() {
  local _

  for _ in 1 2 3 4 5; do
    xmm_log "Unloading xmm7360 module, attempt $_."
    timeout 20s modprobe -r xmm7360 2>/dev/null || true
    if ! lsmod | grep -q '^xmm7360 '; then
      xmm_log "xmm7360 module is unloaded."
      return 0
    fi
    sleep 1
  done

  return 1
}

xmm_prepare_for_reconnect() {
  xmm_stop_service
  xmm_log "Cleaning LTE routes."
  xmm_cleanup_routes
  xmm_log "Bringing $XMM7360_IFACE down if it exists."
  ip link set "$XMM7360_IFACE" down 2>/dev/null || true
  xmm_log "Cleaning LTE DNS."
  xmm_cleanup_dns
  xmm_log "Cleaning stale NetworkManager connection."
  xmm_cleanup_networkmanager
}

xmm_start_service() {
  modprobe -r iosm 2>/dev/null || true
  if ! xmm_driver_is_bound; then
    modprobe xmm7360
  fi
  if ! timeout 100s systemctl start "$XMM7360_SERVICE"; then
    xmm_log "$XMM7360_SERVICE failed during modem setup."
    journalctl -u "$XMM7360_SERVICE" --no-pager -n 40 \
      | grep -E 'failed|ERROR|IP address|DNS server|Attach failed|ConnectSetup|response:' || true
    return 1
  fi
}

xmm_require_service_ok() {
  if systemctl is-failed --quiet "$XMM7360_SERVICE"; then
    xmm_log "$XMM7360_SERVICE failed during modem setup."
    journalctl -u "$XMM7360_SERVICE" --no-pager -n 40 \
      | grep -E 'failed|ERROR|IP address|DNS server|Attach failed|ConnectSetup|response:' || true
    return 1
  fi
}

xmm_wait_for_ip() {
  local timeout="${1:-$XMM7360_WAIT_SECONDS}"
  local waited=0
  local ip_addr

  while [ "$waited" -lt "$timeout" ]; do
    xmm_require_service_ok
    ip_addr="$(xmm_wwan_ip || true)"
    if [ -n "$ip_addr" ]; then
      xmm_log "wwan0 has IPv4 address $ip_addr."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  xmm_log "Timed out waiting ${timeout}s for wwan0 IPv4 address."
  return 1
}

xmm_use_lte_route() {
  local ip_addr

  ip_addr="$(xmm_wwan_ip || true)"
  if [ -z "$ip_addr" ]; then
    xmm_log "wwan0 has no IPv4 address. Run sudo xmm7360-reset first."
    return 1
  fi

  ip route replace default via "$ip_addr" dev "$XMM7360_IFACE"
  xmm_log "LTE default route is now via $ip_addr."
}

xmm_use_lte_dns() {
  xmm_cleanup_dns
  for dns in $XMM7360_DNS_SERVERS; do
    printf 'nameserver %s\n' "$dns"
  done | resolvconf -a "$XMM7360_DNS_KEY" -x
  xmm_log "LTE DNS is active through resolvconf key $XMM7360_DNS_KEY."
}

xmm_verify_packet_flow() {
  ping -I "$XMM7360_IFACE" -c 1 -W 5 "$XMM7360_PING_TARGET" >/dev/null
}

xmm_print_link_counters() {
  ip -s link show "$XMM7360_IFACE" || true
}

xmm_test_packet_flow_verbose() {
  local rc=0

  echo "== route to $XMM7360_PING_TARGET over $XMM7360_IFACE =="
  ip route get "$XMM7360_PING_TARGET" oif "$XMM7360_IFACE" 2>&1 || true

  echo
  echo "== $XMM7360_IFACE counters before ping =="
  xmm_print_link_counters

  echo
  echo "== ping test =="
  ping -I "$XMM7360_IFACE" -c 3 -W 5 "$XMM7360_PING_TARGET" || rc=$?

  echo
  echo "== $XMM7360_IFACE counters after ping =="
  xmm_print_link_counters

  return "$rc"
}

xmm_print_routes() {
  ip route
}

xmm_print_dns() {
  sed -n '1,80p' /etc/resolv.conf || true
  resolvconf -l 2>/dev/null || true
}

xmm_modem_pci_addr() {
  lspci -Dnnd "$XMM7360_PCI_ID" | awk '{ print $1; exit }'
}

xmm_driver_is_bound() {
  lspci -nnk -d "$XMM7360_PCI_ID" | grep -q 'Kernel driver in use: xmm7360'
}

xmm_rpc_exists() {
  [ -e /dev/xmm0/rpc ] || [ -e /dev/wwan0xmmrpc0 ]
}

xmm_reset_pci_function() {
  local pci_addr="$1"
  local pci_path="/sys/bus/pci/devices/$pci_addr"

  if [ ! -e "$pci_path/reset" ]; then
    return 1
  fi

  xmm_log "Resetting PCI function $pci_addr through sysfs reset."
  if [ -r "$pci_path/reset_method" ]; then
    xmm_log "Available reset method(s): $(cat "$pci_path/reset_method")"
  fi

  timeout 15s sh -c 'printf "1\n" > "$1/reset"' sh "$pci_path"
}

xmm_remove_and_rescan_pci() {
  local pci_addr="$1"
  local pci_path="/sys/bus/pci/devices/$pci_addr"

  if [ ! -e "$pci_path/remove" ]; then
    xmm_log "PCI remove path is missing for $pci_addr."
    return 1
  fi

  xmm_log "Removing modem PCI device $pci_addr and rescanning PCI."
  printf '1\n' > "$pci_path/remove"
  xmm_wait_for_pci_absent "$pci_addr" 15

  printf '1\n' > /sys/bus/pci/rescan
  udevadm settle --timeout=10 2>/dev/null || true
}

xmm_acpi_reset() {
  local pci_addr="$1"
  local pci_path="/sys/bus/pci/devices/$pci_addr"
  local cfg_backup="/run/xmm7360-pci-config"

  if [ ! -e "$pci_path/config" ]; then
    xmm_log "PCI config path is missing for $pci_addr."
    return 1
  fi

  xmm_log "Trying ACPI reset method $XMM7360_ACPI_RESET_METHOD."
  dd if="$pci_path/config" of="$cfg_backup" bs=256 count=1 status=none
  if ! modprobe acpi_call; then
    xmm_log "acpi_call is not available in the booted kernel modules."
    xmm_log "If you just rebuilt after adding acpi_call, reboot once so /run/booted-system includes it."
    return 1
  fi

  if [ ! -e /proc/acpi/call ]; then
    xmm_log "/proc/acpi/call is missing after loading acpi_call."
    return 1
  fi

  printf '%s\n' "$XMM7360_ACPI_RESET_METHOD" > /proc/acpi/call
  xmm_log "ACPI reset result: $(cat /proc/acpi/call 2>/dev/null || true)"
  sleep 2

  if [ -e "$pci_path/config" ]; then
    dd of="$pci_path/config" if="$cfg_backup" bs=256 count=1 status=none 2>/dev/null || true
  else
    printf '1\n' > /sys/bus/pci/rescan
    udevadm settle --timeout=10 2>/dev/null || true
  fi

  xmm_log "Waiting ${XMM7360_ACPI_BOOT_WAIT_SECONDS}s for modem firmware after ACPI reset before probing."
  sleep "$XMM7360_ACPI_BOOT_WAIT_SECONDS"
}

xmm_wait_for_pci_absent() {
  local pci_addr="$1"
  local timeout="${2:-15}"
  local waited=0

  while [ "$waited" -lt "$timeout" ]; do
    if [ ! -e "/sys/bus/pci/devices/$pci_addr" ]; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  xmm_log "Timed out waiting for PCI device $pci_addr to disappear."
  return 1
}

xmm_wait_for_pci_present() {
  local timeout="${1:-30}"
  local waited=0
  local pci_addr

  while [ "$waited" -lt "$timeout" ]; do
    pci_addr="$(xmm_modem_pci_addr || true)"
    if [ -n "$pci_addr" ] && [ -e "/sys/bus/pci/devices/$pci_addr" ]; then
      printf '%s\n' "$pci_addr"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  xmm_log "Timed out waiting for modem PCI device $XMM7360_PCI_ID to reappear."
  return 1
}

xmm_probe_or_bind_driver() {
  local pci_addr
  local pci_path

  if xmm_driver_is_bound; then
    return 0
  fi

  pci_addr="$(xmm_modem_pci_addr || true)"
  if [ -z "$pci_addr" ]; then
    return 1
  fi

  pci_path="/sys/bus/pci/devices/$pci_addr"
  modprobe -r iosm 2>/dev/null || true
  modprobe xmm7360

  if xmm_driver_is_bound; then
    return 0
  fi

  printf 'xmm7360\n' > "$pci_path/driver_override" 2>/dev/null || true

  xmm_log "Probing $pci_addr for xmm7360."
  printf '%s\n' "$pci_addr" > /sys/bus/pci/drivers_probe 2>/dev/null || true
  sleep 1

  if xmm_driver_is_bound; then
    return 0
  fi

  xmm_log "Binding $pci_addr to xmm7360."
  printf '%s\n' "$pci_addr" > /sys/bus/pci/drivers/xmm7360/bind 2>/tmp/xmm7360-bind-error || {
    xmm_log "Direct bind failed: $(cat /tmp/xmm7360-bind-error)"
    return 1
  }
}

xmm_wait_for_module_bound() {
  local timeout="${1:-20}"
  local waited=0
  local probed=0

  while [ "$waited" -lt "$timeout" ]; do
    if xmm_driver_is_bound; then
      return 0
    fi
    if [ "$probed" -eq 0 ]; then
      xmm_probe_or_bind_driver || true
      probed=1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  xmm_log "Timed out waiting for xmm7360 driver to bind to $XMM7360_PCI_ID."
  lspci -nnk -d "$XMM7360_PCI_ID" || true
  journalctl -k --no-pager -n 80 | grep -Ei 'xmm|iosm|7360|pci.*05:00|05:00' || true
  return 1
}

xmm_wait_for_rpc() {
  local timeout="${1:-$XMM7360_RPC_WAIT_SECONDS}"
  local waited=0

  while [ "$waited" -lt "$timeout" ]; do
    if xmm_rpc_exists; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  xmm_log "Timed out waiting for XMM RPC device."
  find /dev -maxdepth 3 \( -path '*xmm*' -o -path '*wwan*' \) -print 2>/dev/null || true
  find /sys/bus/pci/devices -maxdepth 3 \( -path '*xmm*' -o -path '*wwan*' \) -print 2>/dev/null || true
  journalctl -k --no-pager -n 80 | grep -Ei 'xmm|iosm|7360|pci.*05:00|05:00' || true
  return 1
}
