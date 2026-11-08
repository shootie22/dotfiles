# Keeps servers from filling up on old system generations. Each rebuild keeps
# the previous system around, and its kernel and initrd in /boot; on mixi's
# small /boot that ran out after about 30 rebuilds (2026-10-01).
{ lib, pkgs, config, ... }:

{
  # Boot menu entries to keep. Old ones stay in the Nix store until the GC
  # below removes them.
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 5;
  boot.loader.grub.configurationLimit = lib.mkDefault 5;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.settings.auto-optimise-store = true;
  # Between the weekly runs: when a build or download leaves less than 2 GiB
  # free, Nix deletes unused store paths until 6 GiB are free. Only garbage,
  # never a generation that's still kept.
  nix.settings.min-free = 2 * 1024 * 1024 * 1024;
  nix.settings.max-free = 6 * 1024 * 1024 * 1024;

  # The weekly run and min-free above go by age and a fixed size; on a small
  # disk 6 GiB free is already nearly full. Every hour: past 80% used, the
  # generations older than a week and everything they alone held go; past
  # 85%, everything not in a kept generation. In host-work.slice
  # (node-budget.nix), so it never competes with the pods.
  systemd.services.nix-keep-free = {
    description = "Keep the Nix store's disk under 80% used";
    serviceConfig = { Type = "oneshot"; Slice = "host-work.slice"; };
    path = [ config.nix.package pkgs.coreutils ];
    script = ''
      used() { df --output=pcent /nix/store | tail -1 | tr -dc 0-9; }
      if [ "$(used)" -ge 80 ]; then
        echo "/nix/store's disk is $(used)% used: removing generations older than a week"
        nix-collect-garbage --delete-older-than 7d
      fi
      if [ "$(used)" -ge 85 ]; then
        echo "still $(used)% used: removing everything no kept generation needs"
        nix-store --gc
      fi
      echo "/nix/store's disk: $(used)% used"
    '';
  };
  systemd.timers.nix-keep-free = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "hourly"; RandomizedDelaySec = "10min"; Persistent = true; };
  };
}
