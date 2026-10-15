# Rolls back a deploy that cuts this host off (infrastructure incident
# 2026-10-14: a live switch on fuji left it unable to reach anything, and
# nothing could undo it without someone at the machine).
#
# Every `interval` seconds: can this host reach at least one other server
# over Nebula (ping)? A system that has been running healthy for
# `acceptAfter` seconds becomes the known-good one (kept from garbage
# collection). If no server answers for `failAfter` seconds while running
# anything else (a deploy, or a boot into a new system), it switches back to
# the known-good system the way comin deploys, holds comin so it doesn't put
# the bad system straight back, and tells the alert relays once the network
# works again. On the known-good system it never acts: an outage that isn't
# a deploy's doing is not its business.
#
# After a rollback, comin stays off until a person has fixed main and lets it
# go again:
#   rm /var/lib/switch-guard/hold && systemctl start comin
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.switchGuard;
  mesh = (import ../../lib/nebula.nix).hosts;
  self = config.networking.hostName;
  state = "/var/lib/switch-guard";
  gcroot = "/nix/var/nix/gcroots/switch-guard-good";

  # Runs on its own, outside the guard's unit: switching back to a system
  # without the guard (or with a different one) would otherwise stop the
  # guard halfway through.
  rollback = pkgs.writeShellScript "switch-guard-rollback" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd config.nix.package pkgs.curl pkgs.jq pkgs.nettools ]}
    good=$1 bad=$2
    echo "rolling back from $bad to $good"
    systemctl stop comin || true
    if [ -e ${cfg.cominProfile} ]; then
      nix-env --profile ${cfg.cominProfile} --set "$good" || echo "couldn't point comin's profile at $good"
    fi
    if "$good/bin/switch-to-configuration" switch; then result="Switched back to the known-good system."
    else result="Switching back FAILED; it needs a person."; fi
    echo "$result"
    msg="$result A deploy left $(hostname) unable to reach any other server for ${toString cfg.failAfter} s. comin is held until main is fixed: rm ${state}/hold && systemctl start comin. Bad system: $bad"
    body=$(jq -n --arg h "$(hostname)" --arg m "$msg" '{title: "Deploy rolled back on \($h)", message: $m, emergency: true}')
    # The network should work again now; give it a minute to come up.
    for i in $(seq 1 12); do
      for url in ${lib.escapeShellArgs cfg.relayUrls}; do
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -d "$body" "$url" >/dev/null && exit 0
      done
      sleep 5
    done
    echo "no alert relay answered"
  '';

  check = pkgs.writeShellScript "switch-guard" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.iputils pkgs.systemd ]}
    now=$(date +%s)
    cur=$(readlink -f /run/current-system)
    good=$(cat ${state}/good 2>/dev/null || true)

    if [ -e ${state}/hold ]; then
      echo "holding after a rollback; clear with: rm ${state}/hold && systemctl start comin"
      exit 0
    fi

    healthy() {
      for p in ${lib.escapeShellArgs cfg.peers}; do
        ping -c 1 -W 2 -q "$p" >/dev/null 2>&1 && return 0
      done
      return 1
    }
    accept() {
      ln -sfn "$cur" ${gcroot}
      echo "$cur" > ${state}/good
      echo "known good now: $cur"
    }

    # When this system was first seen running.
    cand="" cand_at=$now
    [ -f ${state}/candidate ] && read -r cand cand_at < ${state}/candidate
    if [ "$cur" != "$cand" ]; then
      cand=$cur cand_at=$now
      echo "$cand $cand_at" > ${state}/candidate
      rm -f ${state}/failing
      [ "$cur" != "$good" ] && echo "new system: $cur, watching it"
    fi

    if healthy; then
      rm -f ${state}/failing
      # The very first run: whatever runs now was working before the guard.
      if [ -z "$good" ]; then accept
      elif [ "$cur" != "$good" ] && [ $(( now - cand_at )) -ge ${toString cfg.acceptAfter} ]; then accept
      fi
      exit 0
    fi

    if [ -z "$good" ] || [ "$cur" = "$good" ] || [ ! -e "$good/bin/switch-to-configuration" ]; then
      rm -f ${state}/failing
      echo "no server answers, but this isn't a new system: nothing to roll back"
      exit 0
    fi

    since=$now
    if [ -f ${state}/failing ]; then read -r since < ${state}/failing; else echo "$now" > ${state}/failing; fi
    down=$(( now - since ))
    if [ "$down" -lt ${toString cfg.failAfter} ]; then
      echo "no server answers for $down s on a new system; rolling back after ${toString cfg.failAfter} s"
      exit 0
    fi

    touch ${state}/hold
    echo "$cur" > ${state}/rolled-back-from
    rm -f ${state}/failing ${state}/candidate
    systemd-run --unit=switch-guard-rollback --collect --no-block ${rollback} "$good" "$cur"
  '';
in
{
  options.dotfiles.switchGuard = {
    enable = lib.mkEnableOption "rolling back a deploy that cuts this host off";
    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (h: mesh.${h}.ip) (lib.filter (h: h != self) (lib.attrNames mesh));
      description = "Addresses of which at least one must answer a ping (the other servers on Nebula).";
    };
    interval = lib.mkOption { type = lib.types.int; default = 30; };
    failAfter = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds without any peer answering, on a system that isn't the known-good one, before rolling back.";
    };
    acceptAfter = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = "Seconds a new system has to run, healthy, before it becomes the known-good one.";
    };
    relayUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (h: "http://${mesh.${h}.ip}:9190/alert") [ "edge" "mixi" ];
    };
    cominProfile = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/profiles/system-profiles/comin";
      description = "comin's system profile, pointed back at the known-good system too, so the next boot uses it.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${state} 0755 root root -" ];

    systemd.services.switch-guard = {
      description = "Roll back a deploy that cuts this host off";
      serviceConfig = { Type = "oneshot"; ExecStart = check; };
    };
    systemd.timers.switch-guard = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "${toString cfg.interval}s";
        AccuracySec = "5s";
      };
    };

    # After a rollback comin stays off, across reboots too, until the hold is
    # cleared by hand.
    systemd.services.comin.unitConfig.ConditionPathExists = "!${state}/hold";
  };
}
