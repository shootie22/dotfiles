# Headless NixOS server in DK (Lenovo ThinkCentre), k3s agent. Replaces the
# Debian install documented in README.md (infrastructure Phase 2, #17).
# Not installed yet: until the reinstall (#18), nothing here runs anywhere.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot-safety.nix
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
    ../../modules/nixos/initrd-dhcp-handover.nix
    ../../modules/nixos/server-housekeeping.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/nebula-mesh.nix
    ../../modules/nixos/edge-tunnel.nix
    ../../modules/nixos/standby-copy.nix
    ../../modules/nixos/site-failover
  ];

  # The servers' own overlay, next to tailscale (lib/nebula.nix, infrastructure #141).
  dotfiles.nebulaMesh.enable = true;

  # Services with files that move between here and fuji when a site is gone,
  # and stay there (site-failover, infrastructure decisions 6 Oct). The
  # copies go from whichever of the two runs them; fuji's (Baikal, Headscale,
  # legacy-web) arrive in /home/standby/fuji.
  dotfiles.siteFailover.services = {
    privatebin = { data = "/home/main/services/privatebin/data"; peer = "fuji"; initial = true; };
    send-uploads = { data = "/home/main/storage/send-uploads"; peer = "fuji"; initial = true; };
    audiobookshelf = {
      data = "/home/main/services/audiobookshelf";
      peer = "fuji";
      initial = true;
      sqlite = [ "config/absdatabase.sqlite" ];
      exclude = [ "/metadata/cache" ];
    };
    baikal = { data = "/home/standby/fuji/baikal"; peer = "fuji"; sqlite = [ "Specific/db/db.sqlite" ]; };
    gitea = {
      data = "/home/main/services/gitea";
      peer = "fuji";
      initial = true;
      # The old Postgres 14 (Gitea is on CNPG now), and the search index and
      # queues, which Gitea rebuilds.
      exclude = [ "/postgres" "/gitea/indexers" "/gitea/queues" ];
    };
    headscale = { data = "/home/standby/fuji/headscale"; peer = "fuji"; sqlite = [ "db.sqlite" ]; };
    legacy-web = { data = "/home/standby/fuji/legacy-web"; peer = "fuji"; };
  };

  # The receiving side for fuji's copies (infrastructure #142).
  dotfiles.standbyCopy.receive = { enable = true; dir = "/home/standby"; from = [ "fuji" ]; };

  # Boot: boot-safety.nix (systemd-boot, boot counting, watchdog, fallbacks).

  # Nix -----------------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Networking ----------------------------------------------------------------
  networking.hostName = "thinkcentre";
  networking.networkmanager.enable = true;

  # Infrastructure DNS must not depend on DHCP or Tailscale state.
  networking.networkmanager.dns = "none";
  networking.nameservers = [ "1.1.1.1" "9.9.9.9" "8.8.8.8" ];

  services.tailscale = {
    enable = true;
    # Accept fuji's route to its LAN API address (the kubernetes Service
    # endpoint); loosens reverse-path filtering for routed replies.
    useRoutingFeatures = "client";
    extraSetFlags = [ "--accept-routes" "--accept-dns=false" ];
  };

  # Remote disk unlock: from the DK LAN (ssh -t -p 2222 root@<LAN-IP>, e.g.
  # jumping through mixi), or through the edge once the initrd tunnel is on.
  boot.initrd.availableKernelModules = [ "e1000e" ];
  boot.initrd.systemd = {
    enable = true;
    network = {
      enable = true;
      networks."10-lan" = {
        matchConfig.Name = "enp0s31f6";
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
    # Dedicated key: copied into the unencrypted boot image.
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    authorizedKeys = map
      (key: ''restrict,pty,command="systemctl default" ${key}'')
      config.users.users.main.openssh.authorizedKeys.keys;
    # OpenSSH stops answering an address for a while after connections that
    # don't log in. thinkcentre-unlock probes the port first, from mixi, and
    # that locked the real unlock out on the first NixOS boot (2026-10-05).
    extraConfig = "PerSourcePenalties no";
  };

  # Hand the NIC over cleanly from the initrd to NetworkManager (#81).
  dotfiles.lanInterface = "enp0s31f6";

  # Deployed by comin from this repo. No automatic kernel reboots: the disk
  # has to be unlocked by hand after a reboot.
  dotfiles.comin.rebootAt = null;

  # A way in through the edge that doesn't need the tailnet (#103), from the
  # initrd too, for unlocking. Both keys are in lib/edge-tunnels.nix.
  dotfiles.edgeTunnel = {
    enable = true;
    initrd = true;
  };

  services.openssh = {
    enable = true;
    # Logins are granted only by lib/admin-ssh-keys.nix, never by hand.
    authorizedKeysInHomedir = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "main" ];
    };
  };

  # Locale --------------------------------------------------------------------
  time.timeZone = "Europe/Copenhagen";
  # Debian keeps the hardware clock in local time. Read as UTC, NixOS's first
  # boot started two hours ahead until NTP pulled it back, and k3s and comin
  # tripped over the jump (2026-10-05). Same as Debian while it's still there
  # to boot into; can go back to UTC once Debian is retired.
  time.hardwareClockInLocalTime = true;
  i18n.defaultLocale = "en_US.UTF-8";

  # Users ---------------------------------------------------------------------
  # uid and gid 1000 as on Debian: everything under /home/main is owned by
  # main:main.
  users.groups.main.gid = 1000;
  users.users.main = {
    isNormalUser = true;
    uid = 1000;
    group = "main";
    # Keep main's user manager running. Started and stopped by each SSH
    # login, it sometimes was stopping just as comin switched, and the switch
    # counted as failed ("user activation for main failed", 2026-10-05).
    linger = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = builtins.attrValues (import ../../lib/admin-ssh-keys.nix);
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    age
    sops
    borgbackup
    smartmontools
    efibootmgr # the firmware boot entries are set by hand (canTouchEfiVariables = false)
  ];

  services.smartd.enable = true;

  # The Gitea runner pod (infrastructure kubernetes/services/gitea-runner-thinkcentre)
  # runs CI jobs in the host's Docker through /var/run/docker.sock, like on
  # mixi. Images and build layers on /home, not the root volume.
  virtualisation.docker = {
    enable = true;
    daemon.settings.data-root = "/home/docker";
  };
  systemd.services.docker.unitConfig.RequiresMountsFor = [ "/home" ];

  # Kubernetes ----------------------------------------------------------------
  # Rejoins as the same node: /etc/rancher/node/password is carried over from
  # Debian, so the node keeps its name, labels and taints.
  # Since Phase 3 a server: the second etcd member and control plane, on its
  # Nebula address like fuji (infrastructure docs/ha/runbooks/etcd-migration.md).
  services.k3s = {
    enable = true;
    role = "server";
    serverAddr = "https://k3s-api:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
    # Same as fuji's, on its own address; k3s refuses a server whose
    # cluster-wide settings differ.
    extraFlags = [
      "--node-ip=10.99.0.3"
      "--node-external-ip=10.99.0.3"
      "--advertise-address=10.99.0.3"
      "--tls-san=k3s-api"
      "--tls-san=100.64.0.4"
      "--egress-selector-mode=disabled"
      "--flannel-backend=wireguard-native"
      "--flannel-iface=nebula.mesh"
      "--node-label=topology.kubernetes.io/zone=dk"
      "--node-label=db=true"
      "--flannel-external-ip"
    ];
  };

  # k3s only starts once every data mount is there. If the 4 TB disk didn't
  # open, Gitea would otherwise start on an empty repositories folder and new
  # pushes would land on the wrong disk.
  systemd.services.k3s.unitConfig.RequiresMountsFor = [
    "/home"
    "/var/lib/rancher"
    "/home/main/storage"
    "/home/main/services/gitea/git/repositories"
  ];

  # Docker Hub rate-limits anonymous pulls (hit on 2026-10-03). Google's mirror
  # first; k3s falls back to Docker Hub itself when an image isn't there.
  environment.etc."rancher/k3s/registries.yaml".text = ''
    mirrors:
      docker.io:
        endpoint:
          - "https://mirror.gcr.io"
  '';

  # Secrets -------------------------------------------------------------------
  # The age key is the one from the Debian install (/etc/sops/age/keys.txt),
  # copied over during the reinstall.
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.defaultSopsFile = ../../secrets/thinkcentre.yaml;
  # The k3s token and the 4 TB disk's keyfile have their own files, encrypted to
  # the thinkcentre and the personal key (2026-10-04).
  sops.secrets.k3s_server_token = {
    sopsFile = ../../secrets/thinkcentre-k3s.yaml;
    owner = "root";
    mode = "0400";
  };
  sops.secrets.tc_storage_key = {
    sopsFile = ../../secrets/thinkcentre-storage-key.bin;
    format = "binary";
    owner = "root";
    mode = "0400";
  };
  sops.secrets.borg_ssh_private_key = { owner = "root"; mode = "0400"; };
  sops.secrets.borg_repo_passphrase = { owner = "root"; mode = "0400"; };

  # Backup --------------------------------------------------------------------
  programs.ssh.knownHosts."m4-borg" = {
    hostNames = [ "100.64.0.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGMOJiwYgSQmZiK1qEAueUK1DWUruOa0yByKkOgzfwu";
  };

  # Same repository and archive names as the Debian job, so pruning carries on
  # with the existing archives. Now all of /home.
  services.borgbackup.jobs.thinkcentre = {
    paths = [ "/home" ];
    exclude = [
      "/home/rancher" # container images, re-pulled
      "/home/docker" # CI images and build layers
      "/home/thinkcentre-borg-cache"
      "/home/lost+found"
    ];
    repo = "ssh://borgworker@100.64.0.3/Volumes/Expansion/borg_repos/server-backups";
    doInit = false;
    archiveBaseName = "THINKCENTRE---Weekly-backup";
    startAt = "Tue,Thu,Sat,Sun *-*-* 03:00:00 UTC";
    persistentTimer = true;
    compression = "zlib";
    encryption = {
      mode = "repokey";
      passCommand = "cat ${config.sops.secrets.borg_repo_passphrase.path}";
    };
    environment = {
      BORG_RSH = "ssh -i ${config.sops.secrets.borg_ssh_private_key.path} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6";
      BORG_CACHE_DIR = "/home/thinkcentre-borg-cache";
    };
    extraArgs = [ "--remote-path=/opt/homebrew/bin/borg" ];
    extraCreateArgs = [ "--stats" ];
    readWritePaths = [ "/home/thinkcentre-borg-cache" ];
    prune.keep = {
      daily = 7;
      weekly = 4;
      monthly = 6;
      yearly = 1;
    };
    # Borg exits 1 for warnings, and a game world always changes while it's
    # read; that's still a good archive. With the default, the job stopped
    # right after creating it: the archive kept its ".failed" name and prune
    # and compact never ran (first NixOS run, 2026-10-05).
    failOnWarnings = false;
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
