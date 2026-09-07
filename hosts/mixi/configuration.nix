# NixOS configuration for the Apple Silicon Mac mini.
{ pkgs, ... }:

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

  # Nix ----------------------------------------------------------------------
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    max-jobs = 1;
    cores = 4;
  };

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
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    wget
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

  services.komodo-periphery = {
    enable = true;
    inbound.port = 9218;
  };

  systemd.services.komodo-periphery = {
    environment = {
      PERIPHERY_ROOT_DIRECTORY = "/etc/komodo";
      PERIPHERY_SSL_ENABLED = "true";
      PERIPHERY_DISABLE_TERMINALS = "false";
      PERIPHERY_INCLUDE_DISK_MOUNTS = "/etc/hostname";
    };
    serviceConfig = {
      EnvironmentFile = "/etc/komodo-secrets.env";
      SupplementaryGroups = [ "docker" ];
    };
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
