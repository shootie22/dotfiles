# Passes web traffic through to Traefik without terminating TLS: fuji (RO)
# first, the thinkcentre (DK) when fuji's Traefik doesn't answer. Nothing
# points at the edge until failover switches ro.radunenu.com to it.
#
# Health checks ask Traefik itself for a host that doesn't exist, so they
# get Traefik's 404 no matter which services are up. Over HTTPS the check
# uses that name as SNI too, so anything other than Traefik answering on 443
# fails it.
{ config, ... }:

let
  # Over Nebula (lib/nebula.nix), not the tailnet: the way in when RO is down
  # mustn't depend on Headscale (infrastructure #153).
  mesh = (import ../../lib/nebula.nix).hosts;
  servers = ''
        server fuji ${mesh.fuji.ip}:@PORT@ check @CHECK@
        server thinkcentre ${mesh.thinkcentre.ip}:@PORT@ check backup @CHECK@
  '';
  backend = port: check: builtins.replaceStrings [ "@PORT@" "@CHECK@" ] [ (toString port) check ] servers;
in
{
  services.haproxy = {
    enable = true;
    config = ''
      global
        log stdout format raw local0 info
        maxconn 20000

      defaults
        mode tcp
        log global
        option tcplog
        timeout connect 5s
        # Long-lived connections (Headscale, websockets) stay open for hours.
        timeout client 2h
        timeout server 2h
        default-server inter 3s fall 3 rise 2

      frontend http
        bind :80
        bind :::80
        default_backend traefik-http

      frontend https
        bind :443
        bind :::443
        default_backend traefik-https

      backend traefik-http
        option httpchk
        http-check send meth GET uri / ver HTTP/1.1 hdr Host edge-check.invalid
        http-check expect status 404
      ${backend 80 ""}
      backend traefik-https
        option httpchk
        http-check send meth GET uri / ver HTTP/1.1 hdr Host edge-check.invalid
        http-check expect status 404
      ${backend 443 "check-ssl check-sni edge-check.invalid verify none"}
      frontend stats
        # Firewall only opens 8404 on the tailnet. Not bound to the tailnet
        # address itself, so HAProxy starts even before Tailscale is up.
        bind :8404
        mode http
        stats enable
        stats uri /stats
        stats refresh 10s
        # Prometheus on fuji scrapes this (edge proxy health per site).
        http-request use-service prometheus-exporter if { path /metrics }
    '';
  };

  # The NixOS module writes /etc/haproxy.cfg but doesn't reload HAProxy when
  # it changes, so config changes only took effect after a reboot.
  systemd.services.haproxy.reloadTriggers = [ config.environment.etc."haproxy.cfg".source ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
  # The stats page only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8404 ];
}
