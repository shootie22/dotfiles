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

  # KDE applications (Dolphin, Gwenview, Ark) only look for Qt plugins inside
  # their own store path unless QT_PLUGIN_PATH says otherwise, and `qt.enable`
  # is what puts each profile's lib/qt-6/plugins on it. Dolphin's F4 terminal
  # panel is a KPart shipped by Konsole, which lives in a *different* store
  # path, so without this the panel stays missing even with Konsole installed.
  qt.enable = true;

  # Dolphin answers "which application opens this file" out of KDE's service
  # cache (ksycoca), and kbuildsycoca populates that cache by walking the XDG
  # menu file; it never scans share/applications directly. Nothing outside
  # Plasma installs an applications.menu, so without this ksycoca is built with
  # zero application entries and Dolphin offers no handler for any mimetype at
  # all, however correct ~/.config/mimeapps.list happens to be.
  environment.etc."xdg/menus/applications.menu".source = ./applications.menu;

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
