# Desktop host: shares the common + Hyprland-desktop + gaming modules with
# nixpad, but has no LTE modem and gets extra dev/container tooling.
#
# Before this builds, generate real hardware-configuration.nix on the actual
# machine:
#   sudo nixos-generate-config --dir /home/bro/gitrepos/github/dotfiles/hosts/desktop --no-filesystems
# then merge the boot.loader / fileSystems / swapDevices it produces here and
# into hardware-configuration.nix, replacing the TODOs below.

{ config, pkgs, ... }:

let
  unstable = import <nixos-unstable> {
    inherit (pkgs) overlays config;
    system = pkgs.stdenv.hostPlatform.system;
  };
  # Keep in sync with hosts/nixpad/configuration.nix's pin until the
  # nixos-unstable channel ships Noctalia >= 5.0.0.
  noctalia = (builtins.getFlake
    "github:noctalia-dev/noctalia/81f2c83d8e06d8d0398b0a268dc7e19766a9213f")
    .packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix

    # Home Manager
    <home-manager/nixos>

    # Shared modules (see ../../modules/nixos/)
    ../../modules/nixos/common.nix
    ../../modules/nixos/desktop-hyprland.nix
    ../../modules/nixos/gaming.nix
  ];

  _module.args = {
    inherit unstable noctalia;
  };

  modules.gaming.enable = true;

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
    extraGroups = [ "networkmanager" "wheel" "docker" ];
    packages = with pkgs; [];
  };

  # Containers/dev workloads the laptop doesn't need.
  virtualisation.docker.enable = true;
  environment.systemPackages = with pkgs; [
    docker-compose
  ];

  system.stateVersion = "25.11";
}
