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

  # Keep the wired NIC armed for magic packets, including after shutdown.
  networking.networkmanager.connectionConfig."ethernet.wake-on-lan" = 64; # magic

  # Remote disk decryption: unlock over Ethernet with
  # ssh -t -p 2222 root@<LAN-IP> systemctl default
  #
  # Early boot has its own network stack; NetworkManager starts after unlock.
  boot.initrd.availableKernelModules = [ "e1000e" ];
  boot.initrd.systemd = {
    enable = true;
    network = {
      enable = true;
      networks."10-eno1" = {
        matchConfig.Name = "eno1";
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.ClientIdentifier = "mac";
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
  boot.initrd.network.ssh = {
    enable = true;
    port = 2222; # Separate port avoids conflicts with the normal SSH host key.
    # Dedicated key: copied into the unencrypted boot image.
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    authorizedKeys = map
      (key: ''restrict,pty,command="systemctl default" ${key}'')
      config.users.users.fuji.openssh.authorizedKeys.keys;
  };

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

  # Sys packages ----------------------------------------------------------
  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    claude-code
  ];

  # Kubernetes ------------------------------------------------------------
  services.k3s = {
    enable = true;
    role = "server";
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.05";
}
