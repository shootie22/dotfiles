# NixOS configuration for the Apple Silicon Mac mini.
{ lib, pkgs, ... }:

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

  services.komodo-periphery = {
    enable = true;
    package = pkgs.callPackage ../../packages/komodo-periphery-v1.nix { };
    # Only the local FRP client can reach Periphery directly. FRP exposes this
    # listener through the edge endpoint configured in the infrastructure repo.
    inbound = {
      serverEnabled = true;
      bindIp = "127.0.0.1";
      port = 8120;
      ssl.enable = true;
    };

    # Core v1 authenticates inbound Periphery connections with the shared
    # legacy passkey. Keep it in a root-only environment file.
    environmentFile = "/etc/komodo-periphery.env";
  };

  # Do not enter a restart loop before the local passkey file is created.
  systemd.services.komodo-periphery.unitConfig = {
    ConditionPathExists = "/etc/komodo-periphery.env";
  };
  systemd.services.komodo-periphery.environment.PATH = lib.mkForce
    "${pkgs.openssl}/bin:/run/current-system/sw/bin:/run/wrappers/bin";

  services.frp.instances.komodo-periphery = {
    enable = true;
    role = "client";
    environmentFiles = [ "/etc/frp-komodo-periphery.env" ];
    settings = { };
    # Connection details and the token are supplied by the encrypted runtime
    # environment, following the other FRP clients in infrastructure.
    extraConfig = ''
      serverAddr = "{{ .Envs.FRP_SERVER_ADDR }}"
      serverPort = {{ .Envs.FRP_SERVER_PORT }}
      auth.method = "token"
      auth.token = "{{ .Envs.FRP_TOKEN }}"
      transport.tls.enable = true
      log.to = "console"
      log.level = "info"

      [[proxies]]
      name = "komodo-periphery-mixi"
      type = "tcp"
      localIP = "127.0.0.1"
      localPort = 8120
      remotePort = {{ .Envs.FRP_REMOTE_PORT }}
      transport.useEncryption = true
      transport.useCompression = true
    '';
  };

  systemd.services.frp-komodo-periphery.unitConfig = {
    ConditionPathExists = "/etc/frp-komodo-periphery.env";
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
