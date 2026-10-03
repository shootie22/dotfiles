# NixOS configuration for the Apple Silicon Mac mini.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
    ../../modules/nixos/failover-checker
    ../../modules/nixos/server-housekeeping.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/edge-tunnel.nix
    ../../modules/nixos/initrd-dhcp-handover.nix
  ];

  # Deployed by comin from this repo. No automatic kernel reboots: the disk
  # has to be unlocked by hand after a reboot (infrastructure #136).
  dotfiles.comin.rebootAt = null;
  users.motd = "mixi: deployed by comin from github.com/shootie22/dotfiles. Change it there, not here.\n";

  # Apple Silicon ------------------------------------------------------------
  hardware.asahi.enable = true;

  # The Asahi installer puts model-specific, non-redistributable firmware on
  # the EFI partition (/boot/vendorfw). It can't go in this public repo, so
  # the config only pins its checksum, and Nix finds the file in mixi's own
  # store, where it was added once with
  #   nix-store --add-fixed sha256 /boot/vendorfw/firmware.cpio
  # That keeps the config pure, so mixi rebuilds without --impure and comin
  # can deploy it. If the Asahi installer is ever run again (it rewrites the
  # firmware), the rebuild fails with the message below: add the new file the
  # same way and update the hash.
  hardware.asahi.peripheralFirmwareDirectory = "${pkgs.runCommand "asahi-vendorfw" { } ''
    mkdir $out
    ln -s ${pkgs.requireFile {
      name = "firmware.cpio";
      sha256 = "1dvrkvj2qixafvw90jmx0id689ga78whyb4s6x3dg5jz7zk8ixa3";
      message = ''
        mixi's Asahi firmware isn't in the Nix store (or it changed). On mixi:
          nix-store --add-fixed sha256 /boot/vendorfw/firmware.cpio
        and if the hash differs, put the new one in hosts/mixi/configuration.nix.
      '';
    }} $out/firmware.cpio
  ''}";

  boot.loader.systemd-boot.enable = true;
  # /boot is only 476 MB here, and each generation's kernel + initrd takes ~75 MB
  # of it. 5 entries reached 84% on 2026-10-03.
  boot.loader.systemd-boot.configurationLimit = 3;
  # The Asahi boot flow manages the EFI variables outside NixOS.
  boot.loader.efi.canTouchEfiVariables = false;

  boot.initrd.luks.devices.encrypted = {
    device = "/dev/disk/by-uuid/f6134f5f-d5e9-42f6-b3b8-2d5d172389d5";
    preLVM = true;
  };

  # Unlock over Ethernet: ssh -t -p 2222 root@<LAN-IP> systemctl default
  # (or `mixi-unlock` / `unlock-via-edge mixi` from an admin device).
  boot.initrd = {
    availableKernelModules = [ "tg3" ];
    systemd = {
      enable = true;
      network = {
        enable = true;
        networks."10-ethernet" = {
          matchConfig.Name = "end0";
          networkConfig.DHCP = "ipv4";
          # Same client ID as NetworkManager, so the initrd gets the same
          # address (the one mixi-unlock goes to).
          dhcpV4Config.ClientIdentifier = "mac";
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

  # A way in through the edge that doesn't need the tailnet (infrastructure
  # #103). Replaces the old tunnels to RO, which died with RO's port 22.
  # Hand end0 over cleanly from the initrd to NetworkManager (#81).
  dotfiles.lanInterface = "end0";

  dotfiles.edgeTunnel = {
    enable = true;
    initrd = true;
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

  # Reach Gitea straight through Traefik on Fuji (over the tailnet route to
  # Fuji's LAN address) instead of via Cloudflare, which rejects request
  # bodies over 100 MB: the Gitea runner here pushes image layers larger
  # than that. Also keeps registry traffic inside the network.
  networking.hosts."192.168.100.136" = [ "git.radunenu.com" ];

  time.timeZone = "Europe/Oslo";

  # Users --------------------------------------------------------------------
  users.users.mixa = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker" ];
    openssh.authorizedKeys.keys = builtins.attrValues (import ../../lib/admin-ssh-keys.nix);
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
    # Logins are granted only by lib/admin-ssh-keys.nix, never by hand.
    authorizedKeysInHomedir = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
  };

  virtualisation.docker.enable = true;

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
  # The DK vote for failover (infrastructure repo, docs/ha/failover.md), until
  # the thinkcentre runs NixOS. Dry run: it only logs what it would do.
  dotfiles.failoverChecker = {
    enable = true;
    peers = [ "http://100.64.0.9:9180/" ];
  };

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
