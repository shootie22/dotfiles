# Failover checker (infrastructure repo, docs/ha/failover.md). Runs on the
# edge and on a DK machine; each one votes, and when they all agree it
# points ro.radunenu.com at the edge or back.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.failoverChecker;
  python = pkgs.python3.withPackages (ps: [ ps.dnspython ]);
  settings = {
    inherit (cfg) name voters peers;
    dry_run = cfg.dryRun;
    listen = "0.0.0.0:${toString cfg.port}";
    interval = 15;
    fail_after = 180;
    back_after = 600;
    min_interval = 3600;
    ro_name = "ro.radunenu.com";
    ro_dynamic_name = "noc-studios.go.ro";
    edge_name = "edge.radunenu.com";
    edge_ip = "141.95.67.178";
    cloudflare_zone = "radunenu.com";
    cloudflare_nameserver = "nola.ns.cloudflare.com";
    desec_apex_zones = [ "byradu.com" "cubi.tube" "cubtube.lol" "kronorite.com" "radunenu.com" "yeetus.net" ];
  };
in
{
  options.dotfiles.failoverChecker = {
    enable = lib.mkEnableOption "the failover checker";
    name = lib.mkOption { type = lib.types.str; default = config.networking.hostName; };
    voters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "edge" "mixi" ];
      description = "Checkers that must all agree before anything changes.";
    };
    peers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Vote URLs of the other checkers, on the tailnet.";
    };
    port = lib.mkOption { type = lib.types.port; default = 9180; };
    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Only log what would change.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.failover_cloudflare_token.sopsFile = ../../../secrets/failover.yaml;
    sops.secrets.failover_desec_token.sopsFile = ../../../secrets/failover.yaml;

    systemd.services.failover-checker = {
      description = "Failover checker for ro.radunenu.com";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${./checker.py} ${pkgs.writeText "failover-checker.json" (builtins.toJSON settings)}";
        Restart = "always";
        RestartSec = 10;
        DynamicUser = true;
        StateDirectory = "failover-checker";
        LoadCredential = [
          "cloudflare_token:${config.sops.secrets.failover_cloudflare_token.path}"
          "desec_token:${config.sops.secrets.failover_desec_token.path}"
        ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    # Votes only on the tailnet.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
