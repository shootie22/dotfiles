# Desktop host: shares the common + Hyprland-desktop + gaming modules with
# nixpad, but has no LTE modem and gets extra dev/container tooling.
#
# Before this builds, generate real hardware-configuration.nix on the actual
# machine:
#   sudo nixos-generate-config --dir /home/bro/gitrepos/github/dotfiles/hosts/desktop --no-filesystems
# then merge the boot.loader / fileSystems / swapDevices it produces here and
# into hardware-configuration.nix, replacing the TODOs below.

# `unstable` and `noctalia` come from the flake via specialArgs.
{ config, pkgs, unstable, noctalia, ... }:

{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix

    # Shared modules (see ../../modules/nixos/)
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-hyprland.nix
    ../../modules/nixos/gaming.nix
    ../../modules/nixos/docker.nix
  ];

  modules.gaming.enable = true;
  modules.docker.enable = true;

  home-manager.extraSpecialArgs = {
    inherit unstable;
  };

  home-manager.users.bro = import ../../home/bro/hosts/desktop.nix;

  # TODO: confirm against nixos-generate-config output for this machine
  # (UEFI vs BIOS, disk encryption, etc).
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "desktop";
  networking.networkmanager.enable = true;

  # TODO: confirm timezone/locale — copied from nixpad for now.
  time.timeZone = "Europe/Copenhagen";
  i18n.defaultLocale = "en_DK.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "da_DK.UTF-8";
    LC_IDENTIFICATION = "da_DK.UTF-8";
    LC_MEASUREMENT = "da_DK.UTF-8";
    LC_MONETARY = "da_DK.UTF-8";
    LC_NAME = "da_DK.UTF-8";
    LC_NUMERIC = "da_DK.UTF-8";
    LC_PAPER = "da_DK.UTF-8";
    LC_TELEPHONE = "da_DK.UTF-8";
    LC_TIME = "da_DK.UTF-8";
  };

  users.users.bro = {
    isNormalUser = true;
    description = "bro";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [];
  };

  system.stateVersion = "25.11";
}
