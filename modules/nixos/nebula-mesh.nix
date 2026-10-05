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
        # Only lighthouses on the fixed port: another RO host on it would take
        # RO's public 4242 when NATed, the port forwarded to fuji (found in
        # tests/nebula-backbone.nix).
        listen.port = if isLighthouse then mesh.port else 0;
        staticHostMap = lib.mapAttrs' (_: h: lib.nameValuePair h.ip h.reach) lighthouses;
        settings = {
          punchy = { punch = true; respond = true; };
          # fuji is found by name; follow RO's address when it changes.
          static_map.cadence = "5m";
        };
        firewall = {
          outbound = [ { port = "any"; proto = "any"; host = "any"; } ];
          inbound = [ { port = "any"; proto = "any"; group = "servers"; } ];
        };
      };
      # Only certificates from our CA get onto the mesh, and Nebula's own
      # firewall above only lets the servers group in.
      networking.firewall.trustedInterfaces = [ "nebula.mesh" ];
    })
  ]);
}
