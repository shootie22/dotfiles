# NixOS configuration for the Apple Silicon Mac mini.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
  ];

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
      storePaths = [ "${pkgs.openssh}/bin/ssh" ];
      services.ssh-unlock-tunnel = {
        description = "Reverse SSH tunnel for remote disk unlock";
        wantedBy = [ "initrd.target" ];
        after = [ "network.target" "sshd.service" "initrd-nixos-copy-secrets.service" ];
        before = [ "shutdown.target" ];
        conflicts = [ "shutdown.target" ];
        unitConfig = {
          # Start before the encrypted root is mounted; retry if DHCP/DNS
          # or the relay is not ready yet, without blocking local unlock.
          DefaultDependencies = false;
          StartLimitIntervalSec = 0;
        };
        preStart = ''
          /bin/chmod 0600 /etc/ssh/initrd-tunnel/id_ed25519
        '';
        serviceConfig = {
          ExecStart = "${pkgs.openssh}/bin/ssh -F /etc/ssh/initrd-tunnel/config -NT"
            + " -i /etc/ssh/initrd-tunnel/id_ed25519"
            + " -o UserKnownHostsFile=/etc/ssh/initrd-tunnel/known_hosts"
            + " -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes"
            + " -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none"
            + " -o ExitOnForwardFailure=yes -o ConnectTimeout=15"
            + " -o ServerAliveInterval=30 -o ServerAliveCountMax=3"
            + " tunnel";
          Restart = "always";
          RestartSec = "10s";
        };
      };
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
    # Appended at bootloader installation time, outside the Nix store.
    # Keep connection details machine-local. The dedicated client key resides
    # on the unencrypted boot disk and must have restricted relay authorization.
    secrets = {
      "/etc/ssh/initrd-tunnel/id_ed25519" = "/etc/secrets/initrd/tunnel_ed25519";
      "/etc/ssh/initrd-tunnel/config" = "/etc/secrets/initrd/tunnel_config";
      "/etc/ssh/initrd-tunnel/known_hosts" = "/etc/ssh/mixi-tunnel/known_hosts";
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
    gnutar
    git
    openssl
    vim
    wget
    age
    sops
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




  # tailscale ----------------------------------------------------------------
  services.tailscale = {
    enable = true;
    # Accept Fuji's route to its LAN API address (the kubernetes Service
    # endpoint); loosens reverse-path filtering for routed replies.
    useRoutingFeatures = "client";
    extraSetFlags = [ "--accept-routes" ];
  };

  # kubernetes
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://100.64.0.1:6443";
    tokenFile = "/run/secrets/k3s_agent_token";
    extraFlags = [
      "--node-external-ip=100.64.0.2"
      "--node-label=location=denmark"
      "--node-label=hardware=m1"
    ];
  };

  # age sops setup ----------------------------------------------------------
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.defaultSopsFile = ../../secrets/mixi.yaml;

  sops.secrets.k3s_agent_token = {
    owner = "root";
    mode = "0400";
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
