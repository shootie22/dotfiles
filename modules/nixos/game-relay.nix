# Relays the public game ports to the thinkcentre over the tailnet. fuji does
# this for traffic arriving at RO's router, the edge for traffic that arrives
# there during a failover (infrastructure repo, docs/ha/failover.md). One
# list, so both always forward the same ports.
{ config, lib, ... }:

let
  cfg = config.dotfiles.gameRelay;
  target = "100.64.0.4"; # thinkcentre on the tailnet
  ports = [
    { port = 6767;  proto = "tcp"; name = "Minecraft HC"; }
    { port = 51751; proto = "tcp"; name = "Minecraft HC SFTP"; }
    { port = 25565; proto = "tcp"; name = "Minecraft Skyblock"; }
    { port = 19132; proto = "udp"; name = "Minecraft Bedrock"; }
    { port = 24545; proto = "udp"; name = "MegaBopl3D"; }
    { port = 5520;  proto = "udp"; name = "Hytale"; }
    { port = 7777;  proto = "udp"; name = "Crosty"; }
  ];
  portsOf = proto: map (p: p.port) (lib.filter (p: p.proto == proto) ports);
  server = p:
    if p.proto == "tcp" then ''
      server {
        listen ${toString p.port};
        proxy_pass ${target}:${toString p.port};
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
      }
    '' else ''
      server {
        listen ${toString p.port} udp reuseport;
        proxy_pass ${target}:${toString p.port};
        proxy_timeout 2m;
      }
    '';
  firewall = {
    allowedTCPPorts = portsOf "tcp";
    allowedUDPPorts = portsOf "udp";
  };
in
{
  options.dotfiles.gameRelay = {
    enable = lib.mkEnableOption "the game port relay to the thinkcentre";
    interface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Open the ports only on this interface; null opens them everywhere.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall =
      if cfg.interface == null then firewall
      else { interfaces.${cfg.interface} = firewall; };

    services.nginx = {
      enable = true;
      virtualHosts = { };
      streamConfig = lib.concatMapStrings server ports;
    };
  };
}
