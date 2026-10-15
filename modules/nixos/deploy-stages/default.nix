# Staged deploys (infrastructure incident 2026-10-14: one merge reached every
# host within minutes, both entrances included).
#
# A host with `upstream` hosts doesn't deploy a new commit as soon as comin
# has built it. comin's deploy confirmer holds it (mode "manual"), and the
# gate (gate.sh) accepts it once every upstream host has deployed the same
# commit and kept running it for `wait` seconds, or, for a commit that
# doesn't change the upstream hosts (comin there doesn't record it), once it
# has waited `maxWait` with every upstream host healthy. An upstream host
# whose comin doesn't answer blocks it either way: after a rollback the
# switch guard holds comin there, so a change that cut one host off never
# reaches the next.
#
# The stages (set in each host's configuration):
#   thinkcentre, mixi   first (no upstream)
#   fuji, minima        after thinkcentre and mixi
#   edge                after fuji
#
# A commit that has to go out now, past the gate, on one host:
#   sudo comin confirmation accept
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.deployStages;
  mesh = (import ../../../lib/nebula.nix).hosts;
  stateDir = "/var/lib/deploy-gate";
in
{
  options.dotfiles.deployStages = {
    upstream = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames mesh));
      default = [ ];
      description = "Hosts that must have run a commit for `wait` seconds before this one deploys it. Empty: deploy at once.";
    };
    wait = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Seconds every upstream host must have run the commit (longer than the switch guard's 10 minutes to accept, so a rollback there shows first).";
    };
    maxWait = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Seconds after which a waiting commit goes anyway if every upstream host stayed healthy: comin doesn't record a commit that leaves a host unchanged, so a change for this host alone never shows up upstream.";
    };
    interval = lib.mkOption { type = lib.types.int; default = 60; };
  };

  config = lib.mkIf (cfg.upstream != [ ]) {
    services.comin.deployConfirmer.mode = "manual";

    systemd.services.deploy-gate = {
      description = "Let comin deploy once the upstream hosts run the commit";
      path = [ config.services.comin.package pkgs.coreutils pkgs.curl pkgs.jq pkgs.gnugrep ];
      environment = {
        GATE_UPSTREAM = lib.concatMapStringsSep " " (h: "${h}=http://${mesh.${h}.ip}:4243/metrics") cfg.upstream;
        GATE_WAIT = toString cfg.wait;
        GATE_MAX_WAIT = toString cfg.maxWait;
        GATE_STATE = stateDir;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${./gate.sh}";
      };
    };
    systemd.timers.deploy-gate = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "${toString cfg.interval}s";
      };
    };
  };
}
