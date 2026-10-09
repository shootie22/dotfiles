# Relays the public game ports to wherever each game server runs, over
# Nebula. fuji does this for traffic arriving at RO's router, the edge for
# traffic that arrives there during a failover (infrastructure repo,
# docs/ha/failover.md). One list, so both always forward the same ports.
#
# A game with a world moves between the thinkcentre and fuji with its site
# (site-failover); its `service` names it there, and the relay asks the
# site-failover status pages which node holds it, every 10 seconds (the
# stateless games too, with a label and nothing to copy). A game without a
# service goes to the thinkcentre.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.gameRelay;
  mesh = (import ../../lib/nebula.nix).hosts;
  default = mesh.thinkcentre.ip;
  ports = [
    { port = 6767;  proto = "tcp"; name = "Minecraft HC"; service = "minecraft-hc"; }
    { port = 51751; proto = "tcp"; name = "Minecraft HC SFTP"; service = "minecraft-hc"; }
    { port = 25565; proto = "tcp"; name = "Minecraft Skyblock"; service = "minecraft-skyblock"; }
    { port = 19132; proto = "udp"; name = "Minecraft Bedrock"; service = "minecraft-skyblock"; }
    { port = 24545; proto = "udp"; name = "MegaBopl3D"; service = "megabopl3d"; }
    { port = 5520;  proto = "udp"; name = "Hytale"; service = "hytale"; }
    { port = 7777;  proto = "udp"; name = "Crosty"; service = "crosty"; }
    { port = 24567; proto = "udp"; name = "Bopl 2D"; service = "bopl2d"; }
    { port = 25566; proto = "tcp"; name = "hub-test java"; service = "hub-test"; } # hub: hub-test
  ];
  portsOf = proto: map (p: p.port) (lib.filter (p: p.proto == proto) ports);
  services = lib.unique (lib.filter (s: s != null) (map (p: p.service) ports));
  targetsFile = "/run/game-relay/targets.conf";
  statusPort = 9112; # site-failover's status page

  # map $server_port -> the node to send it to.
  targets = pick: ''
    map $server_port $game_target {
    ${lib.concatMapStrings (p: "  ${toString p.port} ${pick p};\n") ports}}
  '';
  defaults = pkgs.writeText "game-relay-targets.conf" (targets (_: default));

  server = p:
    if p.proto == "tcp" then ''
      server {
        listen ${toString p.port};
        proxy_pass $game_target:${toString p.port};
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
      }
    '' else ''
      server {
        listen ${toString p.port} udp reuseport;
        proxy_pass $game_target:${toString p.port};
        proxy_timeout 2m;
      }
    '';

  # Who holds each game's label, as fuji's or the thinkcentre's status page
  # says (whichever answers). Unknown keeps the last answer.
  update = pkgs.writeShellScript "game-relay-targets" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.curl pkgs.gnused pkgs.coreutils pkgs.diffutils ]}
    [ -e ${targetsFile} ] || install -m 0644 ${defaults} ${targetsFile}
    new=$(mktemp)
    cp ${targetsFile} "$new"
    ${lib.concatMapStrings (svc: ''
      holder=""
      for ip in ${mesh.fuji.ip} ${mesh.thinkcentre.ip}; do
        holder=$(curl -s -m 3 http://$ip:${toString statusPort}/${svc} | sed -n 's/.* holder=\([a-z]*\)$/\1/p')
        [ -n "$holder" ] && [ "$holder" != none ] && break
        holder=""
      done
      case "$holder" in
        fuji) ip=${mesh.fuji.ip} ;;
        thinkcentre) ip=${mesh.thinkcentre.ip} ;;
        *) ip="" ;;
      esac
      if [ -n "$ip" ]; then
        ${lib.concatMapStrings (p: ''
          sed -i 's/^  ${toString p.port} .*;$/  ${toString p.port} '"$ip"';/' "$new"
        '') (lib.filter (p: p.service == svc) ports)}
      fi
    '') services}
    if ! cmp -s "$new" ${targetsFile}; then
      chmod 0644 "$new"
      mv "$new" ${targetsFile}
      echo "targets changed:"; cat ${targetsFile}
      /run/current-system/systemd/bin/systemctl reload nginx.service || true
    else
      rm -f "$new"
    fi
  '';

  firewall = {
    allowedTCPPorts = portsOf "tcp";
    allowedUDPPorts = portsOf "udp";
  };
in
{
  options.dotfiles.gameRelay = {
    enable = lib.mkEnableOption "the game port relay";
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
      streamConfig = ''
        include ${targetsFile};
      '' + lib.concatMapStrings server ports;
    };

    # The targets file has to exist before nginx starts: the defaults, until
    # the first update.
    systemd.tmpfiles.rules = [
      "d ${dirOf targetsFile} 0755 root root -"
      "C ${targetsFile} 0644 root root - ${defaults}"
    ];
    systemd.services.nginx = { after = [ "systemd-tmpfiles-setup.service" ]; };

    systemd.services.game-relay-targets = {
      description = "Point the game relay at the node running each game";
      after = [ "nginx.service" ];
      serviceConfig = { Type = "oneshot"; ExecStart = update; };
    };
    systemd.timers.game-relay-targets = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "20s"; OnUnitActiveSec = "10s"; AccuracySec = "1s"; };
    };
  };
}
