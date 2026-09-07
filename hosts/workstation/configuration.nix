# System configuration. User-level settings live in home.nix.
{ lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Boot ----------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # CachyOS kernel: BORE scheduler + LTO, fetched from the chaotic cache.
  boot.kernelPackages = pkgs.linuxPackages_cachyos;

  # Graphical boot: Plymouth splash + graphical LUKS password prompt.
  boot.plymouth.enable = true;
  boot.initrd.kernelModules = [ "amdgpu" ];   # native-resolution splash on the AMD GPU
  boot.kernelParams = [ "quiet" "splash" ];
  boot.consoleLogLevel = 0;
  boot.initrd.verbose = false;

  boot.initrd.luks.devices."luks-b7687213-f176-4061-9b7e-ffabdec4f615".device =
    "/dev/disk/by-uuid/b7687213-f176-4061-9b7e-ffabdec4f615";

  # Encrypted 2TB media HDD: unlocked post-boot with a keyfile on the encrypted
  # root, then mounted. `nofail` so a missing/failed disk never blocks boot.
  environment.etc.crypttab.text = ''
    media  UUID=85cf6af8-c4f9-4aad-bd47-94dc0a5b7e3c  /root/.keys/media.key  luks,nofail
  '';
  fileSystems."/home/nixa/localstorage" = {
    device  = "/dev/mapper/media";
    fsType  = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=20s" ];
  };

  # Nix ---------------------------------------------------------------------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nixpkgs.config.allowUnfree = true;

  # Networking ------------------------------------------------------------
  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  # Locale --------------------------------------------------------------
  time.timeZone = "Europe/Oslo";
  i18n.defaultLocale = "en_US.UTF-8";
  services.xserver.xkb = { layout = "us"; variant = ""; };

  # Desktop: Hyprland + auto-login ------------------------------------------
  programs.hyprland = {
    enable = true;
    withUWSM = true;
  };
  programs.dconf.enable = true;

  # Secret Service for Electron/Chromium apps (Element, etc.).
  services.gnome.gnome-keyring.enable = true;
  services.dbus.packages = [ pkgs.gcr ];   # unlock/create-keyring prompt
  security.pam.services.greetd.enableGnomeKeyring = true;
  security.pam.services.login.enableGnomeKeyring = true;

  # Tap Super = F13 (Noctalia launcher in hyprland.lua); hold Super = modifier.
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings.main.leftmeta = "overload(meta, f13)";
    };
  };
  # keyd must grab the keyboards before the compositor opens them.
  systemd.services.keyd.wantedBy = [ "graphical.target" ];
  systemd.services.greetd.after = [ "keyd.service" ];

  services.greetd = {
    enable = true;
    settings = rec {
      initial_session = { command = "uwsm start hyprland-uwsm.desktop"; user = "nixa"; };
      default_session = initial_session;
    };
  };

  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Noctalia shell — pulls in NetworkManager / Bluetooth / UPower / power-profiles.
  programs.noctalia = {
    enable = true;
    recommendedServices.enable = true;
  };

  # Audio -------------------------------------------------------------
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # Let the DAC follow the source rate instead of resampling everything to 48k.
    # Each device only uses rates it actually supports (FiiO E17K: up to 96k;
    # Behringer UMC404HD: up to 192k).
    extraConfig.pipewire."10-clock-rates".context.properties = {
      "default.clock.rate" = 48000;
      "default.clock.allowed-rates" = [ 44100 48000 88200 96000 176400 192000 ];
    };
  };

  # Graphics (AMD RDNA4) --------------------------------------------------
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;   # needed by Steam / Proton

  # Gaming --------------------------------------------------------------
  programs.steam = {
    enable = true;
    extraCompatPackages = [ pkgs.proton-ge-bin ];   # select "GE-Proton" in Steam Play
    remotePlay.openFirewall = true;
  };
  programs.gamemode.enable = true;

  # Fonts -----------------------------------------------------------
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-color-emoji
    inter
    nerd-fonts.jetbrains-mono
  ];

  # Users -----------------------------------------------------------
  users.users.nixa = {
    isNormalUser = true;
    description = "nixa";
    extraGroups = [ "networkmanager" "wheel" ];
  };

  # Managed by `nix-addpkg --system`; see system-packages.txt.
  environment.systemPackages = import ../../lib/read-packages.nix {
    inherit lib pkgs;
    file = ./system-packages.txt;
  };

  system.stateVersion = "26.05";
}
