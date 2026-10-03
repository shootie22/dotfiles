# The receiving end of the sites' reverse SSH tunnels (infrastructure #103,
# lib/edge-tunnels.nix). The `tunnel` user can't run anything: each key may
# only listen on its own loopback port, nothing else. The edge holds no keys
# for the sites; admins jump through here with their own.
{ lib, pkgs, ... }:

let
  tunnels = lib.filterAttrs (_: t: t.key != null) (import ../../lib/edge-tunnels.nix);
in
{
  users.groups.tunnel = { };
  users.users.tunnel = {
    isSystemUser = true;
    group = "tunnel";
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = lib.mapAttrsToList
      (name: t: ''restrict,port-forwarding,permitlisten="127.0.0.1:${toString t.port}" ${t.key}'')
      tunnels;
  };

  services.openssh.settings.AllowUsers = [ "tunnel" ];
  services.openssh.extraConfig = ''
    Match User tunnel
      AllowTcpForwarding remote
      GatewayPorts no
      PermitTTY no
      PermitTunnel no
      X11Forwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      ForceCommand ${pkgs.coreutils}/bin/false
  '';
}
