{ lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/nebula-mesh.nix
    ../../modules/nixos/infra-facts.nix
  ];

  # The servers' own overlay, next to tailscale (lib/nebula.nix, infrastructure #141).
  dotfiles.nebulaMesh.enable = true;

  networking.hostName = "minima";
  # The flake output is minima-vm, not the hostname.
  services.comin.hostname = "minima-vm";

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

  # Admin devices may log in as the Lima-managed user (not declared here), next
  # to Lima's own key in ~/.ssh/authorized_keys.
  environment.etc."ssh/authorized_keys.d/radu" = {
    text = builtins.concatStringsSep "\n"
      (builtins.attrValues (import ../../lib/admin-ssh-keys.nix)) + "\n";
    mode = "0444";
  };
  # sshd reads the file as the user; the directory must be traversable.
  systemd.tmpfiles.rules = [ "z /etc/ssh/authorized_keys.d 0755 root root -" ];

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
    # The 250 MB ESP holds a kernel+initrd pair (~90 MB) per distinct kernel.
    configurationLimit = 5;
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
    # On the Nebula mesh since Phase 3 (lib/nebula.nix), like the other
    # nodes: it learns the other servers from fuji by itself, and flannel
    # runs inside the mesh.
    serverAddr = "https://k3s-api:6443";
    tokenFile = "/run/secrets/k3s_agent_token";
    extraFlags = [
      "--node-ip=10.99.0.5"
      "--node-external-ip=10.99.0.5"
      "--flannel-iface=nebula.mesh"
      "--node-label=topology.kubernetes.io/zone=ro"
    ];
  };

  systemd.services.k3s = {
    wants = [ "tailscaled.service" ];
    after = [ "tailscaled.service" ];
  };

  system.stateVersion = "26.05";
}
