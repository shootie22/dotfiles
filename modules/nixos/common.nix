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
    unzip
    p7zip
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

  # AirDrop-style LAN file transfer between my machines and phone. The module
  # also opens TCP+UDP 53317, which discovery and receiving both need --
  # installing the package alone leaves this host invisible behind the
  # default firewall.
  programs.localsend.enable = true;

  # Waybar/Noctalia glyphs
  fonts.packages = with pkgs; [
    font-awesome
    noto-fonts
    noto-fonts-color-emoji
    nerd-fonts.symbols-only
    nerd-fonts.jetbrains-mono
  ];

  # Always use Cloudflare for DNS, regardless of what the DHCP lease on
  # whatever network we're connected to hands out. `networking.nameservers`
  # doesn't reliably apply once NetworkManager is managing the connection
  # (it manages resolv.conf itself), so this sets NetworkManager's *global*
  # DNS override instead — it takes priority over any per-connection or
  # DHCP-supplied DNS on every network.
  environment.etc."NetworkManager/conf.d/dns-override.conf".text = ''
    [global-dns-domain-*]
    servers=1.1.1.1,1.0.0.1
  '';
}
