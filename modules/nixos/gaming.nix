# Steam + gaming support, shared across hosts.
#
# Enable per-host with:
#   modules.gaming.enable = true;
{ config, lib, pkgs, unstable ? pkgs, ... }:

let
  cfg = config.modules.gaming;
in
{
  options.modules.gaming = {
    enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = lib.mkIf cfg.enable {
    # udev rules for Steam controllers and other Steam-supported devices.
    hardware.steam-hardware.enable = true;

    programs.steam = {
      enable = true;
      extraCompatPackages = with pkgs; [
        proton-ge-bin
      ];
      extraPackages = with pkgs; [
        gamescope
        mangohud
      ];
      gamescopeSession.enable = true;
      localNetworkGameTransfers.openFirewall = true;
      protontricks.enable = true;
      remotePlay.openFirewall = true;
    };

    programs.gamemode.enable = true;

    environment.systemPackages = with pkgs; [
      supertuxkart
      dolphin-emu
      prismlauncher
      # osu! ships new releases far faster than the 25.11 stable channel
      # backports them; pull it from unstable so it doesn't nag about being
      # out of date.
      unstable.osu-lazer
    ];

    # Sober (Roblox player) is Flatpak-only: VinegarHQ doesn't publish it to
    # nixpkgs or as a Nix flake, only to Flathub. xdg.portal.enable is
    # already set by programs.hyprland, which flatpak requires.
    services.flatpak.enable = true;

    systemd.services.flatpak-sober = {
      description = "Add Flathub remote and install Sober (Roblox)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.flatpak ];
      script = ''
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        flatpak install --system --noninteractive flathub org.vinegarhq.Sober
      '';
      serviceConfig.Type = "oneshot";
    };
  };
}
