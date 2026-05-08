xmm_prepare_for_reconnect

if ! xmm_unload_module; then
  xmm_log "xmm7360 is still loaded. Try sudo xmm7360-hard-reset or reboot."
  exit 1
fi

sleep 2
xmm_start_service
xmm_wait_for_ip "$XMM7360_WAIT_SECONDS"
xmm_log "Reconnect complete. Run sudo xmm7360-use-lte to make LTE primary and verify packet flow."

