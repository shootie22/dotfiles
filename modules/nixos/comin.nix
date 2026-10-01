# Deploys this machine from the dotfiles repo: comin checks main every 60
# seconds and switches to the new config. Kernel changes need a reboot, which
# comin doesn't do, so a nightly timer reboots when the running kernel is
# older than the deployed one. See docs/ha/decisions.md in the
# infrastructure repo.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.comin;
in
{
  options.dotfiles.comin.rebootAt = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = "*-*-* 04:00:00 Europe/Bucharest";
    description = ''
      systemd calendar spec for the nightly check that reboots into a newer
      kernel. null disables automatic reboots, e.g. on hosts whose disk has
      to be unlocked by hand after a reboot.
    '';
  };

  config = {
    services.comin = {
      enable = true;
      remotes = [{
        name = "origin";
        url = "https://github.com/shootie22/dotfiles.git";
        branches.main.name = "main";
      }];
    };

    systemd.services.reboot-for-kernel = lib.mkIf (cfg.rebootAt != null) {
      description = "Reboot if the deployed kernel is newer than the running one";
      serviceConfig.Type = "oneshot";
      script = ''
        booted=$(readlink /run/booted-system/{initrd,kernel,kernel-modules})
        current=$(readlink /run/current-system/{initrd,kernel,kernel-modules})
        if [ "$booted" != "$current" ]; then
          echo "Kernel changed since boot, rebooting"
          ${pkgs.systemd}/bin/systemctl reboot
        fi
      '';
    };

    systemd.timers.reboot-for-kernel = lib.mkIf (cfg.rebootAt != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.rebootAt;
        # Spread hosts a little so they never all reboot in the same second.
        RandomizedDelaySec = "10min";
      };
    };
  };
}
