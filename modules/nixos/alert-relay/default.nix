# Alert relay (infrastructure repo, docs/ha/alerting.md): takes alerts and
# sends each one once, through Pushover or, if that fails, email straight to
# Mailfence. The main one runs on the edge; mixi runs a standby that only
# sends while the edge's doesn't answer (infrastructure #156).
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.alertRelay;
  settings = {
    listen = "0.0.0.0:${toString cfg.port}";
    ack_timeout = 900;   # escalate unacknowledged emergencies after 15 minutes
    dedup_window = 600;  # the same alert twice within 10 minutes is sent once
    max_per_hour = 20;   # non-emergency cap, against alert storms
    email = "alerts@radunenu.com";
    mail_servers = [ "smtp1.mailfence.com" "smtp2.mailfence.com" ];
    standby_for = cfg.standbyFor;
  };
  # The Pushover keys are shared by both relays; the healthchecks.io ping is
  # the edge's alone.
  shared = name: { sopsFile = ../../../secrets/alert-relay.yaml; key = name; };
  secret = name: { sopsFile = ../../../secrets/edge.yaml; key = name; };
in
{
  options.dotfiles.alertRelay = {
    enable = lib.mkEnableOption "the alert relay";
    port = lib.mkOption { type = lib.types.port; default = 9190; };
    standbyFor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The main relay's /health URL; set, this relay only sends while that one doesn't answer.";
    };
    heartbeat = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Ping healthchecks.io every minute (the edge's check).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      relay_pushover_user_key = shared "pushover_user_key";
      relay_pushover_app_token = shared "pushover_app_token";
    } // lib.optionalAttrs cfg.heartbeat {
      relay_healthchecks_url = secret "healthchecks_relay_url";
    };

    systemd.services.alert-relay = {
      description = "Alert relay: Pushover, then email";
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
        ] ++ lib.optional cfg.heartbeat
          "healthchecks_url:${config.sops.secrets.relay_healthchecks_url.path}";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    # Alerts from the tailnet, and over Nebula (a trusted interface).
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ cfg.port ];
  };
}
