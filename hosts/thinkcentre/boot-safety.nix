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
  gateway = "192.168.88.1"; # the DK router
in
{
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
  boot.loader.systemd-boot.extraEntries."nixos-zz-debian-fallback.conf" = ''
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
  boot.initrd.systemd.timers.unlock-timeout = {
    wantedBy = [ "initrd.target" "emergency.target" ];
    timerConfig.OnActiveSec = "45min";
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

  # Boot health: the boot only counts as good (systemd-bless-boot) once the
  # LAN works and sshd runs. If that doesn't happen within 15 minutes, reboot,
  # which uses up a try. A machine that boots but can't be reached is the one
  # state boot counting alone wouldn't catch.
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
    path = [ pkgs.iputils pkgs.iproute2 pkgs.systemd ];
    script = ''
      for i in $(seq 1 90); do
        if systemctl is-active -q sshd.service && ping -c 1 -W 2 ${gateway} >/dev/null; then
          echo "LAN and sshd up after ''${i}0 s"
          exit 0
        fi
        sleep 10
      done
      echo "no LAN or no sshd after 15 minutes, rebooting"
      systemctl reboot
      exit 1
    '';
  };

  # Layer 4 ------------------------------------------------------------------
  # Data mounts never stop the boot; k3s waits for them instead (see
  # configuration.nix), so a missing disk means stopped services, not an
  # unreachable machine or data written to the wrong place.
  fileSystems."/home".options = [ "nofail" ];
}
