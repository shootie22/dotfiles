# Keeps servers from filling up on old system generations. Each rebuild keeps
# the previous system around, and its kernel and initrd in /boot; on mixi's
# small /boot that ran out after about 30 rebuilds (2026-10-01).
{ lib, ... }:

{
  # Boot menu entries to keep. Old ones stay in the Nix store until the GC
  # below removes them.
  boot.loader.systemd-boot.configurationLimit = lib.mkDefault 10;
  boot.loader.grub.configurationLimit = lib.mkDefault 10;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.settings.auto-optimise-store = true;
}
