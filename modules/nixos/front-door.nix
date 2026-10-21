# The front door on fuji and the thinkcentre: an HAProxy that takes the
# site's web traffic (80, 443, Git's SSH on 2022) and passes it, still
# encrypted, to a Traefik that has its routes loaded: this node's, or the
# other site's over Nebula while this one isn't (infrastructure, 2026-10-21).
#
# Before, the router's port forwards and the edge reached Traefik's own ports
# directly. A Traefik that had just started took connections before it had
# loaded its routes and answered 404 for every site until it had: half a
# minute on every restart (k3s upgrades, config changes). A Traefik that's
# gone took the site with it until DNS failover moved.
#
# "Has its routes loaded": an Ingress for traefik-ready.invalid (infrastructure,
# kubernetes/argocd/traefik-ready.yaml) answers Traefik's own /ping, through
# the same entry point middlewares every site has. Before both of Traefik's
# providers and those middlewares are loaded, it's a 404.
#
# Traefik listens on its own host ports for this (httpPort, httpsPort,
# gitsshPort; traefik-config.yaml). The visitor's address goes along in a
# PROXY header; the edge's comes in with one already.
{ config, lib, ... }:

let
  cfg = config.dotfiles.frontDoor;
  mesh = (import ../../lib/nebula.nix).hosts;
  me = mesh.${config.networking.hostName}.ip;
  peer = mesh.${cfg.peer}.ip;
  ready = "check-ssl check-sni traefik-ready.invalid verify none";
in
{
  options.dotfiles.frontDoor = {
    enable = lib.mkEnableOption "the front door in front of this site's Traefik";
    peer = lib.mkOption {
      type = lib.types.enum (lib.attrNames mesh);
      description = "The other site's Traefik node, used while this one's Traefik isn't ready.";
    };
    httpPort = lib.mkOption { type = lib.types.port; default = 10080; };
    httpsPort = lib.mkOption { type = lib.types.port; default = 10443; };
    gitsshPort = lib.mkOption { type = lib.types.port; default = 12022; };
  };

  config = lib.mkIf cfg.enable {
    # The same ports Traefik's host ports took before, on every interface
    # (those bypassed the firewall; a listener doesn't).
    networking.firewall.allowedTCPPorts = [ 80 443 2022 ];
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
          timeout connect 3s
          # Long-lived connections (Headscale, websockets) stay open for hours.
          timeout client 2h
          timeout server 2h
          # A Traefik that stops being ready is out within about 2 s, and back
          # after 2 good checks. A failed connection marks it down at once, so
          # the retry goes to the other one.
          default-server inter 1s fastinter 500ms fall 2 rise 2 observe layer4 error-limit 1 on-error mark-down
          retries 2
          option redispatch

        # Only the edge may say who the visitor is (its own PROXY header);
        # anyone else is the visitor.
        frontend https
          bind :::443 v4v6
          tcp-request connection expect-proxy layer4 if { src ${mesh.edge.ip} }
          default_backend traefik-https
        frontend http
          bind :::80 v4v6
          tcp-request connection expect-proxy layer4 if { src ${mesh.edge.ip} }
          default_backend traefik-http
        frontend gitssh
          bind :::2022 v4v6
          tcp-request connection expect-proxy layer4 if { src ${mesh.edge.ip} }
          default_backend traefik-gitssh

        backend traefik-https
          option httpchk
          http-check send meth GET uri /ping ver HTTP/1.1 hdr Host traefik-ready.invalid
          http-check expect status 200
          server local ${me}:${toString cfg.httpsPort} send-proxy-v2 check ${ready}
          server peer ${peer}:${toString cfg.httpsPort} send-proxy-v2 check ${ready} backup
        # Port 80 and Git's SSH follow the HTTPS checks, rather than checking
        # an SSH connection to Gitea every second.
        backend traefik-http
          server local ${me}:${toString cfg.httpPort} send-proxy-v2 track traefik-https/local
          server peer ${peer}:${toString cfg.httpPort} send-proxy-v2 track traefik-https/peer backup
        backend traefik-gitssh
          server local ${me}:${toString cfg.gitsshPort} send-proxy-v2 track traefik-https/local
          server peer ${peer}:${toString cfg.gitsshPort} send-proxy-v2 track traefik-https/peer backup
      '';
    };
  };
}
