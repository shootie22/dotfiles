# The servers' Nebula backbone (lib/nebula.nix, infrastructure #141).
#
# The host makes its own key pair on the first activation; only the public
# half leaves it, to be signed with the CA. Until its certificate is in
# lib/nebula/<name>.crt, only the key exists and Nebula doesn't run.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.nebulaMesh;
  mesh = import ../../lib/nebula.nix;
  me = mesh.hosts.${cfg.name};
  isLighthouse = me.lighthouse or false;
  lighthouses = lib.filterAttrs (_: h: h.lighthouse or false) mesh.hosts;
  dir = "/var/lib/nebula-mesh";
  certFile = ../../lib/nebula + "/${cfg.name}.crt";
in
{
  options.dotfiles.nebulaMesh = {
    enable = lib.mkEnableOption "the servers' Nebula backbone";
    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "The host's name in lib/nebula.nix.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      system.activationScripts.nebulaMeshKey = lib.stringAfter [ "users" ] ''
        install -d -m 755 ${dir}
        if [ ! -f ${dir}/host.key ]; then
          ${pkgs.nebula}/bin/nebula-cert keygen -out-key ${dir}/host.key -out-pub ${dir}/host.pub
        fi
        chmod 600 ${dir}/host.key
        chmod 644 ${dir}/host.pub
        if id nebula-mesh >/dev/null 2>&1; then chown nebula-mesh ${dir}/host.key; fi
      '';
    }

    (lib.mkIf (builtins.pathExists certFile) {
      services.nebula.networks.mesh = {
        enable = true;
        ca = ../../lib/nebula/ca.crt;
        cert = certFile;
        key = "${dir}/host.key";
        inherit isLighthouse;
        isRelay = isLighthouse;
        # Lighthouses don't list lighthouses.
        lighthouses = lib.optionals (!isLighthouse) (lib.mapAttrsToList (_: h: h.ip) lighthouses);
        relays = lib.optionals (!isLighthouse) (lib.mapAttrsToList (_: h: h.ip) lighthouses);
        # A fixed port everywhere, open in the host firewall, so hosts on the
        # same LAN can reach each other directly (with a random one, the
        # firewall dropped them and they went through a relay). Not 4242
        # except on the lighthouses: another RO host on it would take RO's
        # public 4242 when NATed, the port forwarded to fuji (found in
        # tests/nebula-backbone.nix).
        listen.port = if isLighthouse then mesh.port else mesh.port - 1;
        staticHostMap = lib.mapAttrs' (_: h: lib.nameValuePair h.ip h.reach) lighthouses;
        # IPv6 too: where both ends have it, it's a direct path without NAT.
        listen.host = "[::]";
        settings = {
          punchy = { punch = true; respond = true; };
          # Hosts on the same LAN use it, not a relay or the public route.
          preferred_ranges = lib.optional (me ? lan) me.lan;
          # Scraped by Prometheus over the mesh itself, so a host that's
          # missing there shows up as down (infrastructure monitoring,
          # job nebula). Bound to the mesh address only: tailscale accepts
          # anything on tailscale0 before the host firewall runs.
          stats = {
            type = "prometheus";
            listen = "${me.ip}:8101";
            path = "/metrics";
            namespace = "nebula";
            interval = "15s";
          };
          # fuji is found by name: follow RO's address when it changes, and
          # retry soon when a lookup fails at boot.
          static_map.cadence = "1m";
          # Never run Nebula over the tailnet or the pod network: hosts tell
          # the lighthouses all their addresses by default, tailscale's
          # included, and the mesh would quietly depend on what it's there
          # to replace.
          lighthouse.local_allow_list.interfaces = {
            "tailscale.*" = false;
            "nebula.*" = false;
            "flannel.*" = false;
            "cni.*" = false;
            "veth.*" = false;
            "docker.*" = false;
            "br-.*" = false;
          };
          lighthouse.remote_allow_list = {
            "0.0.0.0/0" = true;
            "::/0" = true;
            "100.64.0.0/10" = false; # tailnet
            "fd7a:115c:a1e0::/48" = false; # tailnet
            "10.42.0.0/16" = false; # pods
            "10.43.0.0/16" = false; # services
            "172.16.0.0/12" = false; # docker
          };
        };
        firewall = {
          outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
          inbound = [ { port = "any"; proto = "any"; group = "servers"; } ];
        };
      };
      # Only certificates from our CA get onto the mesh, and Nebula's own
      # firewall above only lets the servers group in.
      networking.firewall.trustedInterfaces = [ "nebula.mesh" ];

      # The fixed registration address (infrastructure #21): k3s-api is every
      # API server's mesh address, from /etc/hosts, so joining works with any
      # one of them down and needs no DNS. The servers carry the name in
      # their certificate (--tls-san=k3s-api).
      networking.hosts = lib.mkMerge (lib.mapAttrsToList
        (_: h: { ${h.ip} = [ "k3s-api" ]; })
        (lib.filterAttrs (_: h: h.api or false) mesh.hosts));

      # The other direction: tailscale offers its peers every address a host
      # has, Nebula's included, and picked the path through Nebula between
      # fuji and the thinkcentre (6 Oct). Tailscale marks its own packets
      # (0x80000), so refuse those towards the mesh, like k3s-tailnet-guard
      # does for the pod network. Tested in tests/tailscale-off-nebula.nix.
      systemd.services.nebula-mesh-tailnet-guard = {
        description = "Keep tailscale's own traffic off the Nebula mesh";
        wantedBy = [ "multi-user.target" ];
        before = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "-${pkgs.iproute2}/bin/ip rule del priority 5201";
          ExecStart = "${pkgs.iproute2}/bin/ip rule add priority 5201 fwmark 0x80000/0xff0000 to ${mesh.network} unreachable";
          ExecStop = "${pkgs.iproute2}/bin/ip rule del priority 5201";
        };
      };

      # Tailscale's routing table comes before the main one, and fuji's LAN
      # address is routed over the tailnet for DK. On minima, next to fuji,
      # that sent the mesh's own packets to fuji over the tailnet too. Only
      # Nebula's ports: other LAN traffic (pods reaching the API at fuji's LAN
      # address) keeps going the way it does today.
      systemd.services.nebula-mesh-lan-route = lib.mkIf (me ? lan) {
        description = "Send Nebula's packets on the LAN past tailscale's routes";
        wantedBy = [ "multi-user.target" ];
        before = [ "nebula@mesh.service" "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "-${pkgs.iproute2}/bin/ip rule del priority 5205";
          ExecStart = "${pkgs.iproute2}/bin/ip rule add priority 5205 to ${me.lan} ipproto udp dport ${toString (mesh.port - 1)}-${toString mesh.port} lookup main";
          ExecStop = "${pkgs.iproute2}/bin/ip rule del priority 5205";
        };
      };
    })
  ]);
}
