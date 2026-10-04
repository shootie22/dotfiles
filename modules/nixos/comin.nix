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
      # Prometheus on fuji scrapes this over the tailnet (infrastructure
      # #49): alerts when a deployment, build or evaluation fails.
      exporter.port = 4243;
    };

    # tailscale0 for the other hosts; cni0 for fuji, where Prometheus runs in
    # a pod on the same machine.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 4243 ];
    networking.firewall.interfaces.cni0.allowedTCPPorts = [ 4243 ];

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

    # comin hangs when a new commit arrives while it's still evaluating the
    # previous one: it logs "store: no generation with uuid ... has been found"
    # and then nothing, until restarted (infrastructure #140). If that error is
    # its last log line for 15 minutes, restart it. A build in progress keeps
    # logging, so it never matches.
    systemd.services.comin-unstick = {
      description = "Restart comin when it hangs after a cancelled evaluation";
      serviceConfig.Type = "oneshot";
      path = with pkgs; [ systemd coreutils gnugrep curl jq ];
      script = ''
        last=$(journalctl -u comin -n 1 -o short-unix --no-pager --quiet)
        case "$last" in
          *"no generation with uuid"*) ;;
          *) exit 0 ;;
        esac
        at=''${last%%.*}
        age=$(( $(date +%s) - at ))
        if [ "$age" -gt 900 ]; then
          echo "comin stuck for $age s after a cancelled evaluation, restarting it"
          systemctl restart comin
          # Tell the alert relay on the edge, so it doesn't go unnoticed.
          curl -fsS -m 10 -X POST http://100.64.0.9:9190/alert \
            -d "$(jq -n --arg h "$(hostname)" --arg a "$age" \
              '{title: "comin restarted on \($h)", message: "It had hung for \($a) s after a cancelled evaluation (infrastructure #140). Restarted automatically; nothing else to do unless it keeps happening."}')" \
            >/dev/null || echo "relay unreachable"
        fi
      '';
    };
    systemd.timers.comin-unstick = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "5min";
      };
    };
  };
}
