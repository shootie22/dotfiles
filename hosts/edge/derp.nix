# The tailnet's own relay (DERP, infrastructure #38). Devices that can't reach
# each other directly relay through here instead of through Tailscale's
# servers, which stay in Headscale's list as the fallback.
#
# HAProxy terminates TLS for derp.radunenu.com (haproxy.nix) and passes the
# connection on to derper on 3340, which the firewall keeps closed from
# outside. STUN, for devices to find their public address, is UDP 3478.
# --verify-clients asks the local tailscaled whether a device is in our
# tailnet, so it's no open relay for anyone else.
{ pkgs, ... }:

{
  systemd.services.derper = {
    description = "Tailnet relay (DERP)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.tailscale.derper}/bin/derper -a :3340 -http-port -1 -stun-port 3478 -hostname derp.radunenu.com -verify-clients -home blank";
      Restart = "always";
      RestartSec = 5;
      DynamicUser = true;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  networking.firewall.allowedUDPPorts = [ 3478 ];
}
