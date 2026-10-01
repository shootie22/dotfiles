# Passes web traffic through to Traefik without terminating TLS: fuji (RO)
# first, the thinkcentre (DK) when fuji's Traefik doesn't answer. Nothing
# points at the edge until failover switches ro.radunenu.com to it.
#
# Health checks ask Traefik itself for a host that doesn't exist, so they
# get Traefik's 404 no matter which services are up. Over HTTPS the check
# uses that name as SNI too, which also catches fuji's tailnet port 443
# being sent to the private tools proxy instead of Traefik.
{ ... }:

let
  servers = ''
        server fuji 100.64.0.1:@PORT@ check @CHECK@
        server thinkcentre 100.64.0.4:@PORT@ check backup @CHECK@
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
        stats uri /
        stats refresh 10s
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
  # The stats page only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8404 ];
}
