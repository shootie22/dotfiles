# Base system config shared by every host: nix settings, unfree, fonts, and
# the small set of CLI/system packages we always want.
{ config, lib, pkgs, unstable ? pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    # System utils
    vim
    wget
    brightnessctl
    bluetuith
    unstable.wifitui

    # Monitoring vitals
    btop
    htop
    lm_sensors
    nvtopPackages.amd

    # General packages
    unstable.librewolf
    libnotify
    fastfetch

    # Development
    unstable.codex
    gitui
  ];

  # Waybar/Noctalia glyphs
  fonts.packages = with pkgs; [
    font-awesome
    noto-fonts
    noto-fonts-color-emoji
    nerd-fonts.symbols-only
    nerd-fonts.jetbrains-mono
  ];
}
