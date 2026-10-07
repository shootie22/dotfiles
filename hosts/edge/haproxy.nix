# Passes web traffic through to Traefik without terminating TLS: fuji (RO)
# first, the thinkcentre (DK) when fuji's Traefik doesn't answer. Nothing
# points at the edge until failover switches ro.radunenu.com to it.
#
# Health checks, two steps. First the node's site-failover status page:
# it has to say the node reaches the cluster. A node that's cut off, or only
# half back, has a Traefik that answers but can't reach the pods on the
# other site (hs.radunenu.com gave 502 that way in the drill on 2026-10-07).
# Then Traefik itself, for a host that doesn't exist, so it gets Traefik's
# 404 no matter which services are up. Over HTTPS that check uses the name as
# SNI too, so anything other than Traefik answering on 443 fails it.
{ config, pkgs, ... }:

let
  # Names the edge serves itself instead of passing on (infrastructure #160):
  # Element Web, from its copy on the edge (a k3s pod on 127.0.0.1:8085).
  certDir = "/var/lib/edge-certs";
  # Over Nebula (lib/nebula.nix), not the tailnet: the way in when RO is down
  # mustn't depend on Headscale (infrastructure #153).
  mesh = (import ../../lib/nebula.nix).hosts;
  # send-proxy-v2: Traefik learns the visitor's address from a PROXY header
  # (infrastructure #95). The health checks stay plain, which Traefik accepts
  # from the edge too.
  # on-marked-down shutdown-sessions: the passthrough connections are long
  # (websockets, Headscale), so when a node goes down they're cut and the
  # clients reconnect to the other one. Not for Element Web's short requests,
  # where it would also cut a request being retried on the backup.
  servers = ''
        server fuji ${mesh.fuji.ip}:@PORT@ send-proxy-v2 check on-marked-down shutdown-sessions @CHECK@
        server thinkcentre ${mesh.thinkcentre.ip}:@PORT@ send-proxy-v2 check backup on-marked-down shutdown-sessions @CHECK@
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
        # A node that stops answering is out within about 2 s. A refused or
        # failed connection marks it down at once, so the retry goes to the
        # other node (or the backup) instead of failing.
        default-server inter 1s fastinter 500ms fall 2 rise 3 observe layer4 error-limit 1 on-error mark-down
        retries 2
        option redispatch

      frontend http
        bind :80
        bind :::80
        default_backend traefik-http

      frontend https
        bind :443
        bind :::443
        # Read the name the browser asks for, to serve Element Web here.
        tcp-request inspect-delay 5s
        tcp-request content accept if { req.ssl_hello_type 1 }
        use_backend element-tls if { req.ssl_sni -i c.nuke.zip }
        default_backend traefik-https

      # Element Web, terminated here with the certificate cert-manager renews
      # in the cluster (edge-certs below).
      backend element-tls
        server local 127.0.0.1:8443 send-proxy-v2

      frontend element
        mode http
        option httplog
        bind 127.0.0.1:8443 ssl crt ${certDir}/ alpn h2,http/1.1 accept-proxy
        http-request set-header X-Forwarded-Proto https
        default_backend element-web

      # The local copy; if it's gone, the home sites' Traefiks within 2 s.
      backend element-web
        mode http
        option httpchk
        http-check send meth GET uri /version ver HTTP/1.1 hdr Host c.nuke.zip
        http-check expect status 200
        server local 127.0.0.1:8085 check
        server fuji ${mesh.fuji.ip}:443 ssl verify none sni str(c.nuke.zip) check check-sni c.nuke.zip backup
        server thinkcentre ${mesh.thinkcentre.ip}:443 ssl verify none sni str(c.nuke.zip) check check-sni c.nuke.zip backup

      backend traefik-http
        option httpchk
        http-check connect port 9112
        http-check send meth GET uri /gitea
        http-check expect string cluster=ok
        http-check connect default
        http-check send meth GET uri / ver HTTP/1.1 hdr Host edge-check.invalid
        http-check expect status 404
      ${backend 80 ""}
      backend traefik-https
        option httpchk
        http-check connect port 9112
        http-check send meth GET uri /gitea
        http-check expect string cluster=ok
        http-check connect default
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

  # The c.nuke.zip certificate, copied from the cluster every 15 minutes.
  # HAProxy won't start without a certificate for the element frontend, so a
  # self-signed stand-in is made first if there's none yet; the real one
  # replaces it on the first copy. If the cluster can't be reached, the last
  # copy stays (renewed 30 days before it runs out).
  systemd.services.edge-certs-init = {
    description = "A stand-in certificate for HAProxy until the real one is copied";
    wantedBy = [ "multi-user.target" "haproxy.service" ];
    before = [ "haproxy.service" ];
    path = with pkgs; [ coreutils openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      install -d -m 0750 -g haproxy ${certDir}
      pem=${certDir}/c.nuke.zip.pem
      [ -s "$pem" ] && exit 0
      openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=c.nuke.zip \
        -keyout "$pem.key" -out "$pem.crt" 2>/dev/null
      cat "$pem.crt" "$pem.key" > "$pem"; rm -f "$pem.crt" "$pem.key"
      chgrp haproxy "$pem"; chmod 0640 "$pem"
    '';
  };
  systemd.services.edge-certs = {
    description = "Copy Element Web's certificate from the cluster for HAProxy";
    after = [ "edge-certs-init.service" "k3s.service" ];
    wants = [ "edge-certs-init.service" ];
    path = with pkgs; [ coreutils diffutils openssl jq systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      pem=${certDir}/c.nuke.zip.pem
      secret=$(/run/current-system/sw/bin/k3s kubectl -n element-web get secret element-web-tls -o json 2>/dev/null) || {
        echo "cluster not reachable, keeping the current certificate"; exit 0; }
      new=$(mktemp)
      trap 'rm -f "$new"' EXIT
      { echo "$secret" | jq -r '.data["tls.crt"]' | base64 -d
        echo "$secret" | jq -r '.data["tls.key"]' | base64 -d; } > "$new"
      openssl x509 -noout -in "$new" 2>/dev/null || { echo "secret has no certificate"; exit 1; }
      cmp -s "$new" "$pem" && exit 0
      install -m 0640 -g haproxy "$new" "$pem"
      echo "certificate updated: $(openssl x509 -noout -enddate -in "$pem")"
      systemctl reload haproxy.service || true
    '';
  };
  systemd.timers.edge-certs = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "15min"; };
  };

  # The NixOS module writes /etc/haproxy.cfg but doesn't reload HAProxy when
  # it changes, so config changes only took effect after a reboot.
  systemd.services.haproxy.reloadTriggers = [ config.environment.etc."haproxy.cfg".source ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
  # The stats page only on the tailnet.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8404 ];
}
