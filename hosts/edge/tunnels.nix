# The receiving end of the sites' reverse SSH tunnels (infrastructure #103,
# lib/edge-tunnels.nix). The `tunnel` user can't run anything: each key may
# only listen on its own loopback port, nothing else. The edge holds no keys
# for the sites; admins jump through here with their own.
{ lib, pkgs, ... }:

let
  tunnels = lib.filterAttrs (_: t: t.key != null) (import ../../lib/edge-tunnels.nix);
  # The always-on tunnels; the initrd ones only exist while a host waits for
  # its unlock.
  watched = lib.filterAttrs (name: _: !lib.hasSuffix "-initrd" name) tunnels;
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

  # Alert through the relay when a tunnel has been gone for two checks in a
  # row (10 minutes), and again when it's back. Without it, the way in
  # around the tailnet could be broken for weeks without anyone noticing.
  systemd.services.edge-tunnel-check = {
    description = "Check that the sites' reverse tunnels are up";
    path = with pkgs; [ iproute2 curl jq coreutils ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "edge-tunnel-check";
    };
    script = ''
      relay=http://127.0.0.1:9190/alert
      state=$STATE_DIRECTORY
      send() {
        curl -fsS -m 10 -X POST "$relay" -d "$(jq -n --arg t "$1" --arg m "$2" '{title: $t, message: $m}')" >/dev/null \
          || echo "relay unreachable: $1"
      }
      ${lib.concatStrings (lib.mapAttrsToList (name: t: ''
        if ss -ltnH "sport = :${toString t.port}" | grep -q 127.0.0.1; then
          if [ -e "$state/${name}.alerted" ]; then
            send "Tunnel from ${name} is back" "${name} can be reached through the edge again."
          fi
          rm -f "$state/${name}.missed" "$state/${name}.alerted"
        else
          echo "${name}: no tunnel"
          if [ -e "$state/${name}.missed" ] && [ ! -e "$state/${name}.alerted" ]; then
            send "Tunnel from ${name} is down" "${name} has had no tunnel to the edge for 10 minutes, so the way in around the tailnet doesn't work. Check edge-tunnel.service on ${name}."
            touch "$state/${name}.alerted"
          fi
          touch "$state/${name}.missed"
        fi
      '') watched)}
    '';
  };
  systemd.timers.edge-tunnel-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}
