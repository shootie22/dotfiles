{ lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/nixos/k3s-tailnet-guard.nix
  ];

  networking.hostName = "minima";

  # Lima creates/manages the login user at boot.
  users.mutableUsers = true;
  services.lima.enable = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Reachable from the LAN (lan0): keys only.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  security.sudo.wheelNeedsPassword = false;

  # Network ---------------------------------------------------------------
  # eth0 is Lima's user-mode NAT (host <-> guest). The LAN NIC is bridged onto
  # the Mac's Ethernet (hosts/minima/lima.yaml) so Tailscale gets direct paths
  # instead of relays; name it by MAC and prefer it for the default route.
  systemd.network.links."10-lan0" = {
    matchConfig.MACAddress = "52:55:55:4d:4e:01";
    linkConfig.Name = "lan0";
  };
  networking.dhcpcd.extraConfig = ''
    interface lan0
    metric 100
  '';

  # Match the nixos-lima disk image layout.
  boot.loader.grub = {
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  fileSystems."/boot" = {
    device = lib.mkForce "/dev/vda1";
    fsType = "vfat";
    # FAT has no journal: unflushed metadata lost to a VM crash or hard stop
    # once left grub.cfg unreadable and the VM unbootable. Write synchronously;
    # /boot is only written during bootloader installs.
    #
    # Not an automount: containers that mount the host root keep it busy, so
    # it never idles out. Changing mount types needs `nixos-rebuild boot` and
    # a reboot; `switch` drops the system into emergency mode.
    options = [
      "sync"
      "fmask=0077"
      "dmask=0077"
    ];
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
    options = [ "noatime" "nodiratime" "discard" ];
  };

  # Apple Silicon hosts use 16 KiB pages. Venus/krunkit needs the
  # guest to use 16 KiB pages too for GPU blob mappings.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelPatches = [
    {
      name = "arm64-16k-pages";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        ARM64_4K_PAGES = lib.mkForce no;
        ARM64_16K_PAGES = lib.mkForce yes;
        ARM64_64K_PAGES = lib.mkForce no;
        ARM64_VA_BITS_47 = lib.mkForce yes;
      };
    }
  ];

  # Mesa includes the Venus virtio-gpu Vulkan driver.
  hardware.graphics.enable = true;

  environment.systemPackages = with pkgs; [
    gitMinimal
    vulkan-tools
  ];

  services.tailscale = {
    enable = true;
    # Accept Fuji's route to its LAN API address (the kubernetes Service
    # endpoint); loosens reverse-path filtering for routed replies.
    useRoutingFeatures = "client";
    extraSetFlags = [
      "--accept-dns=false"
      "--accept-routes"
    ];
  };

  # k3s node traffic over the tailnet.
  networking.firewall.interfaces.tailscale0 = {
    allowedTCPPorts = [ 10250 ];
    allowedUDPPorts = [ 51820 51821 ];
  };

  # Secrets
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.defaultSopsFile = ../../secrets/minima.yaml;
  sops.secrets.k3s_agent_token = {
    owner = "root";
    mode = "0400";
  };

  # Kubernetes worker
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://100.64.0.1:6443";
    tokenFile = "/run/secrets/k3s_agent_token";

    # Only the external address is the tailnet one. The API server reaches
    # kubelets via ExternalIP first, and Flannel uses it for its endpoint, so
    # k3s never needs the tailnet address to exist when it starts.
    extraFlags = [
      "--node-external-ip=100.64.0.8"
    ];
  };

  systemd.services.k3s = {
    wants = [ "tailscaled.service" ];
    after = [ "tailscaled.service" ];
  };

  system.stateVersion = "26.05";
}
