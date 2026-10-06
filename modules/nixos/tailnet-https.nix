# Sends tailnet HTTPS for this host to the private tools proxy
# (infrastructure kubernetes/services/headlamp/tailnet-proxy-*), so the
# *.infra URLs don't need a port. Traefik holds 443 on the host itself.
# The edge is the exception: it passes public traffic through to Traefik
# here, so its 443 must reach Traefik, not the private proxy.
#
# On fuji and the thinkcentre, so the tools stay reachable with either site
# gone (infrastructure #149).
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.tailnetHttps;
in
{
  options.dotfiles.tailnetHttps = {
    enable = lib.mkEnableOption "forwarding tailnet HTTPS to the private proxy";
    address = lib.mkOption {
      type = lib.types.str;
      description = "This host's tailnet address.";
    };
    edgeAddress = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.9";
      description = "The edge's tailnet address, left alone.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.tailnet-https = {
      description = "Forward tailnet HTTPS to the private proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "firewall.service" ];
      before = [ "k3s.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "-${pkgs.nftables}/bin/nft delete table ip tailnet_https";
      };

      script = ''
        ${pkgs.nftables}/bin/nft -f - <<'EOF'
        add table ip tailnet_https
        flush table ip tailnet_https
        table ip tailnet_https {
          chain prerouting {
            type nat hook prerouting priority -110; policy accept;
            iifname "tailscale0" ip saddr != ${cfg.edgeAddress} ip daddr ${cfg.address} tcp dport 443 counter dnat to ${cfg.address}:8443
          }
        }
        EOF
      '';
    };
  };
}
