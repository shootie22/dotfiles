# Steam + gaming support, shared across hosts.
#
# Enable per-host with:
#   modules.gaming.enable = true;
{ config, lib, pkgs, ... }:

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
      superTuxKart
    ];
  };
}
