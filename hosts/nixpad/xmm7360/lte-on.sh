usage() {
  cat <<'EOF'
Usage: lte-on [OPTIONS]

Activate LTE using the tested XMM7360 flow:
  1. hard-reset the modem through ACPI
  2. attach the data channel
  3. make LTE the default route
  4. enable LTE DNS
  5. verify packet flow

Options:
  -h, --help      Show this help menu.
  -v, --verbose   Print all modem helper output and diagnostics.

Normal mode:
  Shows a spinner while LTE is activated, then prints the public IP and
  location reported by ipinfo.io.

Debug commands:
  xmm7360-status
  journalctl -u xmm7360-connect -f
  sudo xmm7360-hard-reset
  sudo xmm7360-use-lte
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
  echo "== activating LTE =="
  xmm_as_root xmm7360-hard-reset
  xmm_as_root xmm7360-use-lte

  echo
  echo "== public address =="
  xmm_print_public_location

  echo
  echo "== diagnostics =="
  xmm7360-status
  exit 0
fi

log_file="$(mktemp -t lte-on.XXXXXX.log)"
trap 'rm -f "$log_file"' EXIT

xmm_as_root true

(
  xmm_as_root xmm7360-hard-reset
  xmm_as_root xmm7360-use-lte
) >"$log_file" 2>&1 &
pid=$!

if ! xmm_spinner_wait "$pid" "Activating LTE..."; then
  echo "Failed."
  echo "Run lte-on --verbose for diagnostics."
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
