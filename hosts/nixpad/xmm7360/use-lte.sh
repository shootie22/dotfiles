xmm_use_lte_route
xmm_use_lte_dns

if xmm_test_packet_flow_verbose; then
  xmm_log "LTE packet flow works through $XMM7360_IFACE."
  xmm_print_routes
  exit 0
fi

xmm_log "LTE route was added, but packet flow failed. Rolling LTE route and DNS back."
xmm_cleanup_routes
xmm_cleanup_dns
xmm_print_routes
exit 1
