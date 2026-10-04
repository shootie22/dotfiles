# Headless NixOS server in DK (Lenovo ThinkCentre), k3s agent. Replaces the
# Debian install documented in README.md (infrastructure Phase 2, #17).
# Not installed yet: until the reinstall (#18), nothing here runs anywhere.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
    ../../modules/nixos/initrd-dhcp-handover.nix
    ../../modules/nixos/server-housekeeping.nix
    ../../modules/nixos/comin.nix
    ../../modules/nixos/edge-tunnel.nix
  ];

  # Boot ----------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  # Debian stays the firmware's default until NixOS has proven itself. NixOS
  # is started with a one-time BootNext (see the reinstall runbook), so
  # installing the bootloader must not reorder the boot entries.
  boot.loader.efi.canTouchEfiVariables = false;

  # Reboot if the kernel or systemd hangs. Nobody is on site to press the
  # button.
  systemd.watchdog.runtimeTime = "60s";

  # Trial boot (#18): if NixOS doesn't come up properly, reboot. Because it
  # was started with BootNext, a reboot lands back in Debian. Remove both once
  # NixOS is the default.
  #
  # In the initrd: nobody unlocked the disk within 30 minutes.
  boot.initrd.systemd.timers.trial-fallback = {
    wantedBy = [ "initrd.target" ];
    timerConfig.OnActiveSec = "30min";
  };
  boot.initrd.systemd.services.trial-fallback = {
    unitConfig.DefaultDependencies = false;
    serviceConfig.ExecStart = "/bin/systemctl reboot";
  };
  # After boot: fuji isn't reachable over the tailnet 20 minutes in.
  systemd.timers.trial-fallback = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnBootSec = "20min";
  };
  systemd.services.trial-fallback = {
    serviceConfig.Type = "oneshot";
    script = ''
      if ${pkgs.iputils}/bin/ping -c 5 -W 5 100.64.0.1 >/dev/null; then
        echo "fuji reachable over the tailnet, staying in NixOS"
      else
        echo "fuji not reachable, rebooting back into Debian"
        systemctl reboot
      fi
    '';
  };

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
  };

  # Hand the NIC over cleanly from the initrd to NetworkManager (#81).
  dotfiles.lanInterface = "enp0s31f6";

  # Deployed by comin from this repo. No automatic kernel reboots: the disk
  # has to be unlocked by hand after a reboot.
  dotfiles.comin.rebootAt = null;

  # A way in through the edge that doesn't need the tailnet (#103). The
  # initrd part waits until the first activation has generated its key and
  # the keys are in lib/edge-tunnels.nix; see the reinstall runbook.
  dotfiles.edgeTunnel.enable = true;

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
  i18n.defaultLocale = "en_US.UTF-8";

  # Users ---------------------------------------------------------------------
  # uid 1000 as on Debian: everything under /home/main is owned by it.
  users.users.main = {
    isNormalUser = true;
    uid = 1000;
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
  ];

  services.smartd.enable = true;

  # Kubernetes ----------------------------------------------------------------
  # Rejoins as the same node: /etc/rancher/node/password is carried over from
  # Debian, so the node keeps its name, labels and taints.
  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://100.64.0.1:6443";
    tokenFile = config.sops.secrets.k3s_agent_token.path;
    extraFlags = [ "--node-external-ip=100.64.0.4" ];
  };

  # Secrets -------------------------------------------------------------------
  # The age key is the one from the Debian install (/etc/sops/age/keys.txt),
  # copied over during the reinstall.
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  sops.defaultSopsFile = ../../secrets/thinkcentre.yaml;
  # The k3s token and the 4 TB disk's keyfile have their own files, encrypted to
  # the thinkcentre and the personal key (2026-10-04).
  sops.secrets.k3s_agent_token = {
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
  };
  # Borg exits 1 for warnings (a file changed while reading); that's still a
  # good archive. The Debian unit had the same exception.
  systemd.services.borgbackup-job-thinkcentre.serviceConfig.SuccessExitStatus = "1";

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.11";
}
