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

    # comin can hang in two known ways, both until restarted:
    # - a new commit arrives while it's still evaluating the previous one: it
    #   logs "store: no generation with uuid ... has been found" and then
    #   nothing (infrastructure #140)
    # - the clock jumps back: it stops fetching without any error (the
    #   thinkcentre's first NixOS boot, 2026-10-05)
    # Restart it on the first after 15 quiet minutes, on the second when the
    # fetch counter hasn't moved for 45 minutes (it fetches every minute) and
    # it's been quiet for 15. A build in progress keeps logging, so neither
    # interrupts one.
    systemd.services.comin-unstick = {
      description = "Restart comin when it hangs";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "comin-unstick";
      };
      path = with pkgs; [ systemd coreutils gnugrep gawk curl jq ];
      script = ''
        now=$(date +%s)
        last=$(journalctl -u comin -n 1 -o short-unix --no-pager --quiet)
        at=''${last%%.*}
        quiet=$(( now - ''${at:-$now} ))

        restart() {
          echo "restarting comin: $1"
          systemctl restart comin
          rm -f /var/lib/comin-unstick/fetches
          # Tell the alert relay on the edge, so it doesn't go unnoticed.
          curl -fsS -m 10 -X POST http://100.64.0.9:9190/alert \
            -d "$(jq -n --arg h "$(hostname)" --arg r "$1" \
              '{title: "comin restarted on \($h)", message: "\($r). Restarted automatically; nothing else to do unless it keeps happening."}')" \
            >/dev/null || echo "relay unreachable"
          exit 0
        }

        case "$last" in
          *"no generation with uuid"*)
            if [ "$quiet" -gt 900 ]; then
              restart "It had hung for $quiet s after a cancelled evaluation (infrastructure #140)"
            fi ;;
        esac

        # Fetch counter: remember when it last changed.
        count=$(curl -fsS -m 10 http://127.0.0.1:4243/metrics 2>/dev/null \
          | awk '/^comin_fetch_count/ { s += $NF; n++ } END { if (n) print s }')
        [ -n "$count" ] || exit 0
        state=/var/lib/comin-unstick/fetches
        old="" since=""
        if [ -f "$state" ]; then read -r old since < "$state"; fi
        if [ "$count" != "$old" ]; then
          echo "$count $now" > "$state"
          exit 0
        fi
        stalled=$(( now - since ))
        if [ "$stalled" -gt 2700 ] && [ "$quiet" -gt 900 ]; then
          restart "It hadn't fetched for $stalled s"
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
