usage() {
  cat <<'EOF'
Usage: lte-off [OPTIONS]

Return networking to Wi-Fi:
  1. stop the XMM7360 connector service
  2. remove LTE routes
  3. remove LTE DNS
  4. ask NetworkManager to reconnect Wi-Fi

Options:
  -h, --help      Show this help menu.
  -v, --verbose   Print all modem helper output and diagnostics.

Normal mode:
  Shows a spinner while Wi-Fi is restored, then prints the public IP and
  location reported by ipinfo.io.

Debug commands:
  xmm7360-status
  journalctl -u xmm7360-connect -f
  sudo xmm7360-use-wifi
EOF
}

verbose=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--verbose)
      verbose=1
      ;;
    *)
      echo "Unknown option: $arg"
      echo
      usage
      exit 2
      ;;
  esac
done

if [ "$verbose" -eq 1 ]; then
  echo "== restoring Wi-Fi =="
  xmm_as_root xmm7360-use-wifi

  echo
  echo "== public address =="
  xmm_print_public_location

  echo
  echo "== diagnostics =="
  xmm7360-status
  exit 0
fi

log_file="$(mktemp -t lte-off.XXXXXX.log)"
trap 'rm -f "$log_file"' EXIT

xmm_as_root true

xmm_as_root xmm7360-use-wifi >"$log_file" 2>&1 &
pid=$!

if ! xmm_spinner_wait "$pid" "Restoring Wi-Fi..."; then
  echo "Failed."
  echo "Run lte-off --verbose for diagnostics."
  echo
  tail -n 25 "$log_file" || true
  exit 1
fi

summary="$(xmm_public_location || true)"
if [ -n "$summary" ]; then
  echo "Connected! $summary"
else
  echo "Connected! Public IP lookup failed."
fi
