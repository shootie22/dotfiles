# Hourly DNSSEC check for the multi-signer zones, reporting through the
# alert relay (infrastructure repo, issue #78).
{ config, lib, pkgs, ... }:

{
  options.dotfiles.dnssecCheck.enable = lib.mkEnableOption "the hourly DNSSEC check";

  config = lib.mkIf config.dotfiles.dnssecCheck.enable {
    systemd.services.dnssec-check = {
      description = "Check DNSSEC on the multi-signer zones";
      path = with pkgs; [ bind dnsutils curl jq gawk gnugrep coreutils ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${./check.sh}";
        DynamicUser = true;
        StateDirectory = "dnssec-check";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };

    systemd.timers.dnssec-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        RandomizedDelaySec = "5min";
        Persistent = true;
      };
    };
  };
}
