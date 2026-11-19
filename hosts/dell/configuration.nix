# Headless NixOS server in DK (Dell PowerEdge T30, Xeon E3, 32 GB): a k3s
# agent for x86 CI and general compute. Not an etcd member (fuji, the
# thinkcentre and the edge are the three votes) and not a site-failover home:
# nothing here has to survive the machine, so it has no Borg job either.
# Installed with hosts/dell/install (README.md), deployed by comin.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/boot-safety.nix
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
    ../../modules/nixos/e1000e-guard
    ../../modules/nixos/k3s-eviction.nix
    ../../modules/nixos/initrd-dhcp-handover.nix
    ../../modules/nixos/server-housekeeping.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/nebula-mesh.nix
    ../../modules/nixos/infra-facts.nix
    ../../modules/nixos/edge-tunnel.nix
    ../../modules/nixos/kata.nix
  ];

  # The servers' own overlay, next to tailscale (lib/nebula.nix, infrastructure #141).
  dotfiles.nebulaMesh.enable = true;

  # CI jobs run in Kata VMs (modules/nixos/kata.nix, infrastructure
  # kubernetes/services/ci-runner). The main reason this machine exists:
  # CI off the thinkcentre, which holds DK's control plane and services.
  dotfiles.kata = { enable = true; rootlessVmm = true; };

  # Boot -----------------------------------------------------------------------
  # boot-safety.nix: systemd-boot with boot counting, the hardware watchdog,
  # a reboot if nobody unlocks the disk within 45 minutes, and a boot health
  # check against the DK router. Nothing else is on this disk, so the
  # bootloader may set the firmware's boot entry.
  dotfiles.bootSafety = {
    debianFallback = false;
    # disko.nix already marks /var/lib/rancher and /srv/storage nofail.
    dataMounts = [ ];
  };
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10;

  # Nix ------------------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Networking -----------------------------------------------------------------
  networking.hostName = "dell";
  networking.networkmanager.enable = true;

  # Reach Gitea through Traefik over Nebula, not through Cloudflare, which
  # rejects request bodies over 100 MB: the CI runner here pushes image layers
  # larger than that (as the thinkcentre's and mixi's do).
  networking.hosts = let mesh = (import ../../lib/nebula.nix).hosts; in {
    ${mesh.thinkcentre.ip} = [ "git.radunenu.com" ];
    ${mesh.fuji.ip} = [ "git.radunenu.com" ];
  };

  # Infrastructure DNS must not depend on DHCP or Tailscale state.
  networking.networkmanager.dns = "none";
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" "8.8.8.8" ];

  # Keep the wired NIC armed for magic packets, including after shutdown, so
  # mixi or the thinkcentre can wake it.
  networking.networkmanager.connectionConfig."ethernet.wake-on-lan" = 64; # magic

  services.tailscale = {
    enable = true;
    # Joins Headscale by itself on the first boot (the key is single-use;
    # after that tailscaled's state keeps it in).
    authKeyFile = config.sops.secrets.tailscale_authkey.path;
    extraUpFlags = [
      "--login-server=https://hs.radunenu.com"
      "--hostname=dell"
    ];
    # Accept fuji's route to its LAN API address (the kubernetes Service
    # endpoint), like the other DK hosts; loosens reverse-path filtering for
    # routed replies.
    useRoutingFeatures = "client";
    extraSetFlags = [ "--accept-routes" "--accept-dns=false" ];
  };

  # The onboard I219-LM gets its own name, lan0, by its MAC address, in the
  # initrd (a .link file is copied there too) and after it. The firmware's
  # SMBIOS table points the "Intel LOM" at the wrong PCI address, so udev
  # can't call it eno1 and names it enp0s31f6 by slot instead, and a BIOS
  # update could change that on an unattended machine whose disk unlock
  # depends on the name. The install script checks the MAC before wiping.
  systemd.network.links."10-lan" = {
    matchConfig.PermanentMACAddress = "e4:54:e8:67:26:e6";
    linkConfig.Name = "lan0";
  };

  # Remote disk unlock: from the DK LAN (ssh -t -p 2222 root@<LAN-IP>), or
  # through the edge (`unlock-via-edge dell`).
  boot.initrd.systemd = {
    network = {
      enable = true;
      networks."10-lan" = {
        matchConfig.Name = "lan0";
        networkConfig.DHCP = "ipv4";
        # Same client ID as NetworkManager, so the initrd gets the same address.
        dhcpV4Config.ClientIdentifier = "mac";
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
  boot.initrd.network.ssh = {
    enable = true;
    port = 2222; # Separate port avoids conflicts with the normal SSH host key.
    # Dedicated key, placed by the install script: it's copied into the
    # unencrypted boot image.
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    authorizedKeys = map
      (key: ''restrict,pty,command="systemctl default" ${key}'')
      config.users.users.dell.openssh.authorizedKeys.keys;
    # OpenSSH stops answering an address for a while after connections that
    # don't log in (the thinkcentre's first NixOS boot, 2026-10-05).
    extraConfig = "PerSourcePenalties no";
  };

  # Hand the NIC over cleanly from the initrd to NetworkManager (#81).
  dotfiles.lanInterface = "lan0";

  # Deployed by comin from this repo. No automatic kernel reboots: the disk
  # has to be unlocked by hand after a reboot.
  dotfiles.comin.rebootAt = null;
  # Staged deploys (modules/nixos/deploy-stages): first, with the thinkcentre
  # and mixi. It's a worker with nothing on it that can't be rebuilt, the
  # cheapest place for a bad commit to show.

  # A way in through the edge that doesn't need the tailnet (#103), from the
  # initrd too. The keys are made by hosts/dell/bootstrap and placed by the
  # install script, so both tunnels work from the first boot.
  dotfiles.edgeTunnel = {
    enable = true;
    initrd = true;
  };

  services.openssh = {
    enable = true;
    # Logins are granted only by lib/admin-ssh-keys.nix, never by hand.
    authorizedKeysInHomedir = false;
    # Only the ed25519 key: it's the one kept in secrets/dell-bootstrap.yaml,
    # and sops-nix derives this host's age key from it.
    hostKeys = [
      { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "dell" ];
    };
  };

  # Locale ---------------------------------------------------------------------
  time.timeZone = "Europe/Copenhagen";
  i18n.defaultLocale = "en_US.UTF-8";

  # Users ----------------------------------------------------------------------
  # No passwords anywhere, like the edge: SSH keys are the only way in, and
  # sudo doesn't ask.
  users.mutableUsers = false;
  users.users.dell = {
    isNormalUser = true;
    # Keep the user manager running, so a login ending mid-switch doesn't
    # fail comin's activation (the thinkcentre, 2026-10-05).
    linger = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = builtins.attrValues (import ../../lib/admin-ssh-keys.nix);
  };
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [
    git
    vim
    age
    sops
    smartmontools
    efibootmgr
  ];

  # Hardware -------------------------------------------------------------------
  services.smartd.enable = true;
  # Machine-check errors (CPU, caches) in the journal. The RAM it came with
  # isn't ECC, so memory errors only show up here with ECC modules.
  hardware.rasdaemon.enable = true;

  # Big writes on a SATA SSD. By default the kernel lets writers fill 10-20%
  # of RAM with unwritten data (3-6 GB here) before it holds them back, then
  # pushes it at the disk in one go: a SATA disk has a single queue of 32
  # requests, a cheap one slows to HDD speeds once its cache is full, and
  # everything else that touches the disk (an fsync, a read) waits behind
  # the flood for seconds. Start writing out at 64 MB and hold writers back
  # at 256 MB, so they're slowed to the disk's own pace from the start and
  # there's never much queued. Costs nothing a server notices. Could go
  # once the system disk is an NVMe, but does no harm there either.
  # The other two parts are in disko.nix (dm-crypt without its work queues,
  # no `discard` mounts), and CI VMs are capped by kata.nix (ciIo).
  boot.kernel.sysctl = {
    "vm.dirty_background_bytes" = 64 * 1024 * 1024;
    "vm.dirty_bytes" = 256 * 1024 * 1024;
  };

  # No SATA link power saving. With the kernel's default here
  # (min_power_with_partial) the Kingston SSD stopped answering a write three
  # times in 15 minutes of a full-disk write test (2026-11-19, "SError:
  # { CommWake }", link reset after 30 s); with max_performance it ran another
  # 50 minutes without one. Despite the name, the option applies to desktop
  # chipsets too. 1 = max_performance.
  boot.kernelParams = [ "ahci.mobile_lpm_policy=1" ];

  # Kubernetes -----------------------------------------------------------------
  services.k3s = {
    enable = true;
    role = "agent";
    # On the Nebula mesh (lib/nebula.nix). Joins through k3s-api, which is
    # every API server (#21).
    serverAddr = "https://k3s-api:6443";
    tokenFile = config.sops.secrets.k3s_agent_token.path;
    extraFlags = [
      "--node-ip=10.99.0.6"
      "--node-external-ip=10.99.0.6"
      "--flannel-iface=nebula.mesh"
      "--node-label=topology.kubernetes.io/zone=dk"
    ];
  };

  # containerd's images and the CI jobs live on their own volume; k3s must
  # never start on an empty mount point and fill / instead.
  systemd.services.k3s.unitConfig.RequiresMountsFor = [ "/var/lib/rancher" ];

  # Docker Hub rate-limits anonymous pulls (hit on 2026-10-03). Google's mirror
  # first; k3s falls back to Docker Hub itself when an image isn't there.
  environment.etc."rancher/k3s/registries.yaml".text = ''
    mirrors:
      docker.io:
        endpoint:
          - "https://mirror.gcr.io"
  '';

  # Memory: 2 GiB for the OS and k3s (no etcd here), 1.5 GiB for comin and
  # the Nix GC (systems come from the build cache, nothing is compiled); the
  # rest for pods (modules/nixos/node-budget.nix). Revisit after a week of
  # measured use, like the others.
  dotfiles.nodeBudget = { coreMiB = 2048; hostWorkMiB = 1536; evictionMiB = 768; };

  # Secrets --------------------------------------------------------------------
  # The age identity comes from the SSH host key (ssh-to-age), as on the edge,
  # so there's no separate age key to keep.
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.defaultSopsFile = ../../secrets/dell.yaml;
  sops.secrets.tailscale_authkey = { };
  sops.secrets.k3s_agent_token = { owner = "root"; mode = "0400"; };
  sops.secrets.dell_storage_key = {
    sopsFile = ../../secrets/dell-storage-key.bin;
    format = "binary";
    owner = "root";
    mode = "0400";
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
