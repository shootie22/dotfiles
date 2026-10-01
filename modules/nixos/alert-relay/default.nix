# Alert relay on the edge (infrastructure repo, docs/ha/alerting.md): takes
# alerts over the tailnet and sends each one once, through Pushover or, if
# that fails, ntfy.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.alertRelay;
  settings = {
    listen = "0.0.0.0:${toString cfg.port}";
    ack_timeout = 900;   # escalate unacknowledged emergencies after 15 minutes
    dedup_window = 600;  # the same alert twice within 10 minutes is sent once
    max_per_hour = 20;   # non-emergency cap, against alert storms
  };
  secret = name: { sopsFile = ../../../secrets/edge.yaml; key = name; };
in
{
  options.dotfiles.alertRelay = {
    enable = lib.mkEnableOption "the alert relay";
    port = lib.mkOption { type = lib.types.port; default = 9190; };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.relay_pushover_user_key = secret "pushover_user_key";
    sops.secrets.relay_pushover_app_token = secret "pushover_app_token";
    sops.secrets.relay_ntfy_topic = secret "ntfy_topic";

    systemd.services.alert-relay = {
      description = "Alert relay: Pushover, then ntfy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${./relay.py} ${pkgs.writeText "alert-relay.json" (builtins.toJSON settings)}";
        Restart = "always";
        RestartSec = 5;
        DynamicUser = true;
        LoadCredential = [
          "pushover_user_key:${config.sops.secrets.relay_pushover_user_key.path}"
          "pushover_app_token:${config.sops.secrets.relay_pushover_app_token.path}"
          "ntfy_topic:${config.sops.secrets.relay_ntfy_topic.path}"
        ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    # Alerts only from the tailnet.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
