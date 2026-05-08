xmm_stop_service
xmm_cleanup_routes
xmm_cleanup_dns
xmm_cleanup_networkmanager

nmcli radio wifi on 2>/dev/null || true
nmcli device connect "$XMM7360_WIFI_IFACE" 2>/dev/null || true

xmm_log "Removed LTE route/DNS and asked NetworkManager to reconnect Wi-Fi."
xmm_print_routes

