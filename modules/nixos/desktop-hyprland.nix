# Shared Hyprland desktop-environment config: compositor, greeter, graphics,
# keyring, and the packages Noctalia/Hyprland need. Import on any host that
# should boot into the Hyprland session.
#
# `noctalia` is passed in via `_module.args` from the host config, since it's
# pinned to a specific flake revision rather than pulled from nixpkgs.
{ config, lib, pkgs, noctalia, ... }:

{
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # BlueZ backend for Bluetooth managers like bluetuith.
  hardware.bluetooth.enable = true;

  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };

  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    kitty
    wl-clipboard
    grim
    ffmpegthumbnailer
    slurp
    wf-recorder
  ] ++ [
    noctalia # bar, notifications, launcher, clipboard, wallpaper (pinned v5, see host config)
  ];

  # Keyring
  services.gnome.gnome-keyring.enable = true;

  # Battery/power stats for noctalia's battery widget.
  # (Its power-profile toggle would want power-profiles-daemon, but that
  # conflicts with TLP, so we skip it.)
  services.upower.enable = true;

  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        user = "greeter";
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'uwsm start hyprland-uwsm.desktop'";
      };
    };
  };
}
