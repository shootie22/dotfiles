# Boot safety for a machine nobody can reach physically (infrastructure #18,
# docs/ha/runbooks/thinkcentre-reinstall.md). Every way a boot can go wrong
# has to end in a reboot into something that works, never in a machine that
# sits there unreachable. The layers:
#
#   1. Firmware: Debian stays first in the boot order during the trial;
#      NixOS is only started with a one-time BootNext.
#   2. systemd-boot: boot counting. A generation that fails to boot three times
#      is marked bad and skipped; during the trial the next entry is Debian.
#   3. Things that turn "stuck" into "reboot": kernel panic, the hardware
#      watchdog, nobody unlocking the disk in time, and a boot health check.
#   4. No emergency mode: a missing data disk leaves the machine reachable
#      over SSH with k3s stopped, instead of halting the boot.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.bootSafety;
in
{
  # Defaults are the real thinkcentre; the rehearsal VM (rehearsal/) shortens
  # the timeouts and points the health check at QEMU's gateway.
  options.dotfiles.bootSafety = {
    gateway = lib.mkOption {
      type = lib.types.str;
      default = "192.168.88.1"; # the DK router
      description = "Address the boot health check pings to decide the LAN works.";
    };
    unlockTimeout = lib.mkOption {
      type = lib.types.str;
      default = "45min";
      description = "Reboot if the disk hasn't been unlocked by then.";
    };
    healthChecks = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Health check attempts, 10 s apart, before rebooting.";
    };
    debianFallback = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Offer Debian as the entry after all bad NixOS generations (trial only).";
    };
  };

  config = {
    boot.loader.systemd-boot.enable = true;
    # Debian stays the firmware's default until NixOS has proven itself, so
    # installing the bootloader must not touch the firmware's boot entries.
    boot.loader.efi.canTouchEfiVariables = false;

    # Layer 2 ------------------------------------------------------------------
    boot.loader.systemd-boot.bootCounting = {
      enable = true;
      tries = 3;
    };
    # During the trial: Debian, through its own shim and GRUB, as the entry
    # systemd-boot falls back to once every NixOS generation is marked bad. The
    # name has to match systemd-boot's `nixos-*` default, and the sort key puts
    # it after every NixOS generation. Remove it together with Debian.
    boot.loader.systemd-boot.extraEntries."nixos-zz-debian-fallback.conf" = lib.mkIf cfg.debianFallback ''
      title Debian (fallback during the NixOS trial)
      sort-key zzz-debian
      efi /EFI/debian/shimx64.efi
    '';

    # Layer 3 ------------------------------------------------------------------
    # Reboot 10 s after a kernel panic or oops, like Debian does here.
    boot.kernelParams = [ "panic=10" ];
    boot.kernel.sysctl."kernel.panic_on_oops" = 1;

    # Hardware watchdog (iTCO_wdt, checked to register on this board): reboots
    # if systemd stops responding, in the initrd as well as after it.
    boot.initrd.kernelModules = [ "iTCO_wdt" ];
    boot.initrd.systemd.settings.Manager.RuntimeWatchdogSec = "60s";
    systemd.settings.Manager = {
      RuntimeWatchdogSec = "60s";
      RebootWatchdogSec = "10min";
    };

    # Nobody unlocked the disk within 45 minutes: reboot. During the trial that
    # lands in Debian (BootNext is gone); later it uses up one boot-counting try.
    # IgnoreOnIsolate keeps it running if the initrd falls into emergency mode.
    # That also carried it over the switch to the real system, where it has no
    # unit file and showed up failed (first real boot, 2026-10-05), so it's
    # stopped explicitly before the switch.
    boot.initrd.systemd.timers.unlock-timeout = {
      wantedBy = [ "initrd.target" "emergency.target" ];
      conflicts = [ "initrd-switch-root.target" ];
      before = [ "initrd-switch-root.target" ];
      timerConfig.OnActiveSec = cfg.unlockTimeout;
      unitConfig = {
        DefaultDependencies = false;
        IgnoreOnIsolate = true;
      };
    };
    boot.initrd.systemd.services.unlock-timeout = {
      unitConfig = {
        DefaultDependencies = false;
        IgnoreOnIsolate = true;
      };
      serviceConfig.ExecStart = "/bin/systemctl reboot";
    };

    # Boot health: the boot only counts as good (systemd-bless-boot) once sshd
    # runs and the LAN answers: the router replies to a ping or, if pings are
    # filtered, to ARP. If not within the allowed time, a generation that
    # hasn't proven itself yet reboots, which uses up one of its tries. One
    # that already booted fine before doesn't: then the network is the
    # problem, and rebooting into the same thing would just loop.
    systemd.services.boot-health = {
      description = "Check the machine is reachable before marking the boot good";
      wantedBy = [ "multi-user.target" ];
      requiredBy = [ "boot-complete.target" ];
      before = [ "boot-complete.target" ];
      after = [ "network-online.target" "sshd.service" ];
      wants = [ "network-online.target" ];
      unitConfig.IgnoreOnIsolate = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "20min";
      };
      path = [ pkgs.iputils pkgs.iproute2 pkgs.systemd pkgs.gnused ];
      script = ''
        gw=${cfg.gateway}
        lan_ok() {
          ping -c 1 -W 2 "$gw" >/dev/null 2>&1 && return 0
          dev=$(ip route get "$gw" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
          [ -n "$dev" ] && arping -q -c 1 -w 2 -I "$dev" "$gw"
        }
        for i in $(seq 1 ${toString cfg.healthChecks}); do
          if systemctl is-active -q sshd.service && lan_ok; then
            echo "LAN and sshd up after ''${i}0 s"
            exit 0
          fi
          sleep 10
        done
        state=$(${pkgs.systemd}/lib/systemd/systemd-bless-boot status 2>/dev/null || true)
        case "$state" in
          clean|good)
            echo "no LAN or no sshd, but this generation has booted fine before; not rebooting"
            exit 1
            ;;
        esac
        echo "no LAN or no sshd after ${toString cfg.healthChecks}0 s on an unproven generation ($state), rebooting"
        systemctl reboot
        exit 1
      '';
    };

    # Layer 4 ------------------------------------------------------------------
    # Data mounts never stop the boot; k3s waits for them instead (see
    # configuration.nix), so a missing disk means stopped services, not an
    # unreachable machine or data written to the wrong place.
    fileSystems."/home".options = [ "nofail" ];
  };
}
