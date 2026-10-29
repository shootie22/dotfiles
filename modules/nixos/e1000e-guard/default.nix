# Intel e1000e cards (fuji's I219-LM, the thinkcentre's) can freeze their transmit
# queue under sending load ("Detected Hardware Unit Hang"), and the driver doesn't get
# them going again: fuji was cut off until it was power-cycled
# (incidents/2026-10-29-fuji-network-card-hang in the infrastructure repo).
#
# - TCP segmentation offload (TSO and GSO) is turned off on every e1000e card, at boot,
#   on every switch, and whenever a card appears (after the watchdog reloads the
#   driver). This is the usual workaround. Changing it doesn't reset the link: the
#   driver's e1000_set_features only sets a flag for TSO/GSO. RX checksum and VLAN
#   offloads stay on (changing those does reset the card), and so does EEE (its
#   setter reinitialises the card, and it's inactive on fuji's link anyway).
# - A watchdog resets a card that hung and cut the host off (watchdog.sh).
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.e1000eGuard;
  ethtool = "${pkgs.ethtool}/bin/ethtool";

  offloadsOff = pkgs.writeShellScript "e1000e-offloads-off" ''
    for dev in /sys/class/net/*; do
      iface=$(basename "$dev")
      [ "$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null)")" = e1000e ] || continue
      ${ethtool} -K "$iface" tso off gso off
      echo "$iface: $(${ethtool} -k "$iface" | grep -E '^(tcp|generic)-segmentation-offload:' | tr '\n' ' ')"
    done
  '';

  watchdog = pkgs.writeShellApplication {
    name = "e1000e-watchdog";
    runtimeInputs = with pkgs; [ coreutils gawk gnugrep iproute2 iputils kmod systemd util-linux ];
    text = builtins.readFile ./watchdog.sh;
  };
in
{
  options.dotfiles.e1000eGuard.watchdogDryRun = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Only log what the watchdog would do, for trying it on a new host with a fake hang message (watchdog.sh). Tested on fuji 2026-10-29.";
  };

  config = {
    # Boot and every switch.
    systemd.services.e1000e-offloads = {
      description = "Turn off segmentation offload on e1000e cards";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      restartTriggers = [ offloadsOff ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = offloadsOff;
      };
    };

    # A card that appears later (driver reloaded by the watchdog).
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="net", DRIVERS=="e1000e", RUN+="${ethtool} -K %k tso off gso off"
    '';

    environment.systemPackages = [ pkgs.ethtool watchdog ];

    systemd.services.e1000e-watchdog = {
      description = "Reset a hung e1000e card";
      environment.DRY_RUN = if cfg.watchdogDryRun then "1" else "0";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe watchdog;
      };
    };
    systemd.timers.e1000e-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "30s";
        AccuracySec = "5s";
      };
    };
  };
}
