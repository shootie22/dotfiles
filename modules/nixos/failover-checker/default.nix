# Failover checkers (infrastructure repo, docs/ha/failover.md).
#
# failoverChecker: on the edge and mixi; when they all agree RO is down, it
# points ro.radunenu.com at the edge, and back.
#
# nsChecker (infrastructure #77): on the edge, mixi and fuji; when two of
# them agree Cloudflare's DNS has been down for 45 minutes, it switches the
# zones' nameservers at Porkbun to deSEC, and back after 6 healthy hours.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.failoverChecker;
  ns = config.dotfiles.nsChecker;
  mesh = (import ../../../lib/nebula.nix).hosts;
  python = pkgs.python3.withPackages (ps: [ ps.dnspython ]);
  relayUrls = map (h: "http://${mesh.${h}.ip}:9190/alert") [ "edge" "mixi" ];
  nsVoters = [ "edge" "mixi" "fuji" ];
  nsSettings = {
    name = config.networking.hostName;
    voters = nsVoters;
    quorum = 2;
    peers = map (h: "http://${mesh.${h}.ip}:${toString ns.port}/")
      (lib.filter (h: h != config.networking.hostName) nsVoters);
    dry_run = ns.dryRun;
    listen = "0.0.0.0:${toString ns.port}";
    interval = 60;
    fail_after = 2700; # 45 minutes
    back_after = 21600; # 6 hours
    min_interval = 86400; # once a day per zone
    zones = [ "byradu.com" "cubi.tube" "cubtube.lol" "kronorite.com" "radunenu.com" "yeetus.net" ];
    cloudflare_ns = [ "nola.ns.cloudflare.com" "phil.ns.cloudflare.com" ];
    desec_ns = [ "ns1.desec.io" "ns2.desec.org" ];
    relay_urls = relayUrls;
  };
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
    # The edge's relay, then mixi's standby (infrastructure #156), over Nebula.
    relay_urls = relayUrls;
    desec_apex_zones = [ "byradu.com" "cubi.tube" "cubtube.lol" "kronorite.com" "radunenu.com" "yeetus.net" ];
  };
in
{
  options.dotfiles.nsChecker = {
    enable = lib.mkEnableOption "the nameserver checker (infrastructure #77)";
    port = lib.mkOption { type = lib.types.port; default = 9181; };
    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Only log and report what would change.";
    };
  };

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

  config = lib.mkMerge [ (lib.mkIf ns.enable {
    sops.secrets.failover_porkbun_api_key = { sopsFile = ../../../secrets/failover.yaml; key = "porkbun_api_key"; };
    sops.secrets.failover_porkbun_secret_api_key = { sopsFile = ../../../secrets/failover.yaml; key = "porkbun_secret_api_key"; };

    systemd.services.ns-checker = {
      description = "Nameserver checker: Cloudflare or deSEC";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${./ns-checker.py} ${pkgs.writeText "ns-checker.json" (builtins.toJSON nsSettings)}";
        Restart = "always";
        RestartSec = 10;
        DynamicUser = true;
        StateDirectory = "ns-checker";
        LoadCredential = [
          "porkbun_api_key:${config.sops.secrets.failover_porkbun_api_key.path}"
          "porkbun_secret_api_key:${config.sops.secrets.failover_porkbun_secret_api_key.path}"
        ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
    # Votes go over Nebula, a trusted interface; nothing to open.
  }) (lib.mkIf cfg.enable {
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
  }) ];
}
