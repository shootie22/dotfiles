# Headless NixOS server (Fujitsu Esprimo Q958).
{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Boot ----------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Nix -------------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Networking ------------------------------------------------------------
  networking.hostName = "fuji";
  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "fuji" ];
    };
  };
  networking.firewall.interfaces.eno1.allowedTCPPorts = [ 22 ];

  # Locale ------------------------------------------------------------------
  time.timeZone = "Europe/Bucharest";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ro_RO.UTF-8";
    LC_IDENTIFICATION = "ro_RO.UTF-8";
    LC_MEASUREMENT = "ro_RO.UTF-8";
    LC_MONETARY = "ro_RO.UTF-8";
    LC_NAME = "ro_RO.UTF-8";
    LC_NUMERIC = "ro_RO.UTF-8";
    LC_PAPER = "ro_RO.UTF-8";
    LC_TELEPHONE = "ro_RO.UTF-8";
    LC_TIME = "ro_RO.UTF-8";
  };
  services.xserver.xkb = { layout = "us"; variant = ""; };

  # Users -----------------------------------------------------------------
  users.users.fuji = {
    isNormalUser = true;
    description = "fuji";
    extraGroups = [ "wheel" "networkmanager" ];
    # Machine-local public keys, outside this public repository. Rebuild with
    # --impure to read this file. Only public keys may go here: Nix stores them.
    openssh.authorizedKeys.keys = lib.filter
      (line: line != "" && !(lib.hasPrefix "#" line))
      (lib.splitString "\n" (builtins.readFile "/etc/secrets/ssh/authorized_keys"));
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    claude-code
  ];

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.05";
}
