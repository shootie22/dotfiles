echo "== service =="
systemctl --no-pager --plain status "$XMM7360_SERVICE" || true

echo
echo "== driver =="
lspci -nnk | grep -A4 -i xmm || true

echo
echo "== wwan0 =="
ip addr show "$XMM7360_IFACE" || true

echo
echo "== wwan0 counters =="
ip -s link show "$XMM7360_IFACE" || true

echo
echo "== routes =="
xmm_print_routes

echo
echo "== route test =="
ip route get "$XMM7360_PING_TARGET" oif "$XMM7360_IFACE" 2>/dev/null || true

echo
echo "== packet test =="
if xmm_test_packet_flow_verbose; then
  echo "packet flow works through $XMM7360_IFACE"
else
  echo "packet flow does not work through $XMM7360_IFACE"
fi

echo
echo "== dns =="
xmm_print_dns

echo
echo "== recent modem log =="
journalctl -u "$XMM7360_SERVICE" --no-pager -n 60 \
  | grep -E 'IP address|DNS server|Attach failed|ConnectSetup|response:|RegisteredPlmn|ActivateStatus' || true
