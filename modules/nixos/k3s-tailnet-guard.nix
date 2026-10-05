# K3s nodes run Flannel's WireGuard overlay on top of Tailscale. Tailscale
# offers every local address as a peer endpoint, including pod-network
# addresses, so peers try to reach each other through flannel-wg: the tailnet
# would tunnel through an overlay that itself runs over the tailnet.
#
# Tailscale marks its own transport sockets with 0x80000. Refuse routes from
# those sockets into the pod network, so Tailscale only uses real endpoints
# (or DERP). Pod traffic itself is unmarked and unaffected.
#
# thinkcentre (Debian) carries the same rule in
# hosts/thinkcentre/k3s-tailnet-guard.service.
{ pkgs, ... }:

let
  ip = "${pkgs.iproute2}/bin/ip";
  # Before Tailscale's own rules (5210-5270).
  rule = "priority 5200 fwmark 0x80000/0xff0000 to 10.42.0.0/16 unreachable";
in
{
  systemd.services.k3s-tailnet-guard = {
    description = "Keep Tailscale transport out of the Kubernetes pod network";
    wantedBy = [ "multi-user.target" ];
    before = [ "tailscaled.service" "k3s.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStartPre = "-${ip} rule del priority 5200";
      ExecStart = "${ip} rule add ${rule}";
      ExecStop = "${ip} rule del priority 5200";
    };
  };

  # k3s uses the node's tailnet address. Started before tailscale0 has it,
  # k3s exits ("failed to find interface with specified node ip") and only
  # comes up after a few restarts (thinkcentre's first NixOS boot,
  # 2026-10-05). Wait for the address, at most 2 minutes, then start anyway.
  systemd.services.k3s = {
    wants = [ "tailscaled.service" ];
    after = [ "tailscaled.service" ];
    serviceConfig.ExecStartPre = [
      "-${pkgs.writeShellScript "k3s-wait-tailnet" ''
        for _ in $(seq 1 120); do
          ${ip} -4 addr show dev tailscale0 2>/dev/null | grep -q 'inet 100\.64\.' && exit 0
          sleep 1
        done
        echo "no tailnet address after 2 minutes, starting k3s anyway"
        exit 1
      ''}"
    ];
  };
}
