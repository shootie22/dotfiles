pci_addr="$(xmm_modem_pci_addr || true)"
if [ -z "$pci_addr" ]; then
  xmm_log "Could not find modem PCI device $XMM7360_PCI_ID."
  exit 1
fi

xmm_log "Hard-resetting modem PCI device $pci_addr."
xmm_prepare_for_reconnect

xmm_log "Preparing to unload xmm7360 before ACPI reset."
if ! xmm_unload_module; then
  xmm_log "xmm7360 is still loaded; refusing PCI remove while driver is attached."
  exit 1
fi

xmm_log "Running ACPI reset."
xmm_acpi_reset "$pci_addr"
if ! xmm_wait_for_module_bound 30; then
  xmm_log "ACPI reset did not bind the driver; falling back to PCI remove/rescan."
  pci_addr="$(xmm_modem_pci_addr || true)"
  if [ -z "$pci_addr" ]; then
    printf '1\n' > /sys/bus/pci/rescan
    pci_addr="$(xmm_wait_for_pci_present 30)"
  fi
  xmm_remove_and_rescan_pci "$pci_addr"
  pci_addr="$(xmm_wait_for_pci_present 30)"
  xmm_log "Modem PCI device reappeared as $pci_addr."
  xmm_wait_for_module_bound 30
fi

xmm_log "xmm7360 driver is bound. Waiting ${XMM7360_HARD_RESET_SETTLE_SECONDS}s for modem firmware to settle."
sleep "$XMM7360_HARD_RESET_SETTLE_SECONDS"
xmm_wait_for_rpc "$XMM7360_RPC_WAIT_SECONDS"

xmm_start_service
xmm_wait_for_ip "$XMM7360_WAIT_SECONDS"
xmm_log "Hard reset complete. Run sudo xmm7360-use-lte to make LTE primary and verify packet flow."
