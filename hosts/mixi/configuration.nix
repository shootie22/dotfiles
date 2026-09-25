# NixOS configuration for the Apple Silicon Mac mini.
{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Apple Silicon ------------------------------------------------------------
  hardware.asahi.enable = true;

  # The Asahi installer puts model-specific, non-redistributable firmware on
  # the EFI system partition. It cannot be committed to this public repo, so
  # mixi evaluates this one host with --impure and imports the pinned local
  # archive into the Nix store during each rebuild.
  hardware.asahi.peripheralFirmwareDirectory = /boot/vendorfw;

  boot.loader.systemd-boot.enable = true;
  # The Asahi boot flow manages the EFI variables outside NixOS.
  boot.loader.efi.canTouchEfiVariables = false;

  boot.initrd.luks.devices.encrypted = {
    device = "/dev/disk/by-uuid/f6134f5f-d5e9-42f6-b3b8-2d5d172389d5";
    preLVM = true;
  };

  # Unlock over Ethernet: ssh -t -p 2222 root@<LAN-IP> systemctl default
  boot.initrd = {
    availableKernelModules = [ "tg3" ];
    systemd = {
      enable = true;
      network = {
        enable = true;
        networks."10-ethernet" = {
          matchConfig.Name = "end0";
          networkConfig.DHCP = "ipv4";
        };
      };
    };
    network.ssh = {
      enable = true;
      port = 2222; # Separate port avoids conflicts with the normal SSH host key.
      # Dedicated key: copied into the unencrypted boot image.
      hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
      authorizedKeys = config.users.users.mixa.openssh.authorizedKeys.keys;
    };
  };

  # Nix ----------------------------------------------------------------------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    max-jobs = 1;
    cores = 4;
  };
  nixpkgs.config.allowUnfree = true;

  # Network ------------------------------------------------------------------
  networking.hostName = "mixi";
  networking.networkmanager.enable = true;


  time.timeZone = "Europe/Oslo";

  # Users --------------------------------------------------------------------
  users.users.mixa = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIP0XJEU56o+KB9aZkRR+hGRotn5tbnHd7xfqGFXJt2U nixa@nix-wks"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDHTTANn82vHV1t8BPgWPwH37Y3fnIT/12clqLjqqv98 radu@radus-Mac-mini.local"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    openssl
    vim
    wget
    (callPackage ../../pkgs/antigravity-cli { })
  ];

  # Services -----------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
  };

  virtualisation.docker.enable = true;

  systemd.services.ssh-tunnel = {
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "sshd.service" ];
    unitConfig = {
      ConditionPathExists = [
        "/etc/ssh/mixi-tunnel/id_ed25519"
        "/etc/ssh/mixi-tunnel/known_hosts"
        "/etc/ssh/mixi-tunnel/config"
      ];
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      DynamicUser = true;
      LoadCredential = [
        "identity:/etc/ssh/mixi-tunnel/id_ed25519"
        "known_hosts:/etc/ssh/mixi-tunnel/known_hosts"
        "config:/etc/ssh/mixi-tunnel/config"
      ];
      ExecStart = "${pkgs.openssh}/bin/ssh -F %d/config -NT"
        + " -i %d/identity"
        + " -o UserKnownHostsFile=%d/known_hosts"
        + " -o StrictHostKeyChecking=yes"
        + " -o BatchMode=yes -o IdentitiesOnly=yes"
        + " -o ExitOnForwardFailure=yes -o ConnectTimeout=15"
        + " -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
        + " tunnel";
      Restart = "always";
      RestartSec = "10s";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };




  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
