# Weekly update proposal (infrastructure repo, #84): every Saturday night fuji
# updates flake.lock, builds every x86_64 host with it, and pushes an
# update-DATE branch that a GitHub workflow turns into a pull request. The
# deploy key can push those branches but not main (a ruleset on the repo), so
# nothing changes on the servers until the PR is merged.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.weeklyUpdate;
in
{
  options.dotfiles.weeklyUpdate.enable = lib.mkEnableOption "the weekly flake.lock update proposal";

  config = lib.mkIf cfg.enable {
    sops.secrets.weekly_update_deploy_key = {
      sopsFile = ../../../secrets/weekly-update.yaml;
      key = "deploy_key";
    };
    sops.secrets.weekly_update_ping_url = {
      sopsFile = ../../../secrets/weekly-update.yaml;
      key = "healthchecks_ping_url";
    };

    # Builds run inside the nix-daemon, not this service, so limits go on the
    # daemon: lowest CPU and IO priority, and at most 2 cores. fuji runs the
    # control plane and RO's Traefik; builds must never starve those. The
    # heavy building moves to remote builders with Phase 2 (infrastructure
    # #111).
    nix.daemonCPUSchedPolicy = "idle";
    nix.daemonIOSchedClass = "idle";
    nix.settings.cores = 2;
    nix.settings.max-jobs = 1;

    # The desktops use these caches; without them fuji would compile codex and
    # the CachyOS kernel itself every week.
    nix.settings.extra-substituters = [
      "https://cache.numtide.com"
      "https://noctalia.cachix.org"
      "https://nyx-cache.chaotic.cx/"
    ];
    nix.settings.extra-trusted-public-keys = [
      "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
      "nyx-cache.chaotic.cx:dJxTrgMC3V3cFfyIiBQDQorG6k1LsqurH/srpMSq7qk="
    ];

    systemd.services.weekly-update = {
      description = "Propose a flake.lock update as a pull request";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ nix git openssh jq curl gnugrep gnused coreutils ];
      environment.KNOWN_HOSTS = "${./github_known_hosts}";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${./update.sh}";
        DynamicUser = true;
        StateDirectory = "weekly-update";
        LoadCredential = [
          "deploy_key:${config.sops.secrets.weekly_update_deploy_key.path}"
          "ping_url:${config.sops.secrets.weekly_update_ping_url.path}"
        ];
        Nice = 10;
        TimeoutStartSec = "6h";
      };
    };

    systemd.timers.weekly-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sat 02:00 Europe/Bucharest";
        Persistent = true;
      };
    };
  };
}
