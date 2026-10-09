# tofu applier (infra-hub #48): applies new DNS records from the
# infrastructure repo's main on its own, so a deploy from Hub doesn't wait for
# someone to run scripts/tofu apply. On fuji because fuji's age key already
# decrypts tofu/secrets.sops.yaml; the Gitea runners run every repo's CI with
# the host's Docker socket, so the provider tokens don't go there. Only plans
# that are exactly the changed DNS records get applied (see apply.sh).
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.tofuApply;
in
{
  options.dotfiles.tofuApply.enable = lib.mkEnableOption "applying new DNS records from the infrastructure repo";

  config = lib.mkIf cfg.enable {
    # Can push to the infrastructure repo's main (the ruleset lets this key
    # through); scripts/create-tofu-apply-key.sh makes it.
    sops.secrets.tofu_apply_deploy_key = {
      sopsFile = ../../../secrets/tofu-apply.yaml;
      key = "deploy_key";
    };

    systemd.services.tofu-apply = {
      description = "Apply new DNS records from the infrastructure repo";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ opentofu sops git openssh jq curl gawk diffutils gnugrep gnused coreutils ];
      environment = {
        KNOWN_HOSTS = "${./github_known_hosts}";
        RECORDS_AWK = "${./records.awk}";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${./apply.sh}";
        DynamicUser = true;
        StateDirectory = "tofu-apply";
        LoadCredential = [
          "deploy_key:${config.sops.secrets.tofu_apply_deploy_key.path}"
          "age_key:${config.sops.age.keyFile}"
        ];
        TimeoutStartSec = "15min";
        Nice = 5;
      };
    };

    systemd.timers.tofu-apply = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "2min";
      };
    };
  };
}
