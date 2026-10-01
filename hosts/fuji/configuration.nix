# Headless NixOS server (Fujitsu Esprimo Q958).
{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./raw-edge.nix
    ../../modules/nixos/k3s-tailnet-guard.nix
    ../../modules/nixos/k3s-dns.nix
    ../../modules/nixos/initrd-dhcp-handover.nix
    ../../modules/nixos/server-housekeeping.nix
  ];

  # Boot ----------------------------------------------------------------------
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Nix -------------------------------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  # Networking ------------------------------------------------------------
  networking.hostName = "fuji";
  networking.networkmanager.enable = true;

  # Infrastructure DNS must not depend on DHCP or Tailscale state.
  networking.networkmanager.dns = "none";
  networking.nameservers = [
    "1.1.1.1"
    "9.9.9.9"
    "8.8.8.8"
  ];

  # tailscale
  services.tailscale = {
    enable = true;

    extraSetFlags = [
      # Keep Fuji's host DNS independent from the tailnet control plane.
      "--accept-dns=false"

      # The API server stays advertised on the LAN address, so Fuji's own
      # pods (Traefik -> Headscale) never need the tailnet to reach it. Remote
      # nodes reach that one address through the tailnet instead.
      "--advertise-routes=192.168.100.136/32"
    ];
  };

  # Keep the wired NIC armed for magic packets, including after shutdown.
  networking.networkmanager.connectionConfig."ethernet.wake-on-lan" = 64; # magic

  # Remote disk decryption: unlock over Ethernet with
  # ssh -t -p 2222 root@<LAN-IP> systemctl default
  #
  # Early boot has its own network stack; NetworkManager starts after unlock.
  boot.initrd.availableKernelModules = [ "e1000e" ];
  boot.initrd.systemd = {
    enable = true;
    network = {
      enable = true;
      networks."10-eno1" = {
        matchConfig.Name = "eno1";
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.ClientIdentifier = "mac";
        linkConfig.RequiredForOnline = "no";
      };
    };
  };
  # Hand eno1 over cleanly from the initrd to NetworkManager.
  dotfiles.lanInterface = "eno1";

  boot.initrd.network.ssh = {
    enable = true;
    port = 2222; # Separate port avoids conflicts with the normal SSH host key.
    # Dedicated key: copied into the unencrypted boot image.
    hostKeys = [ "/etc/secrets/initrd/ssh_host_ed25519_key" ];
    authorizedKeys = map
      (key: ''restrict,pty,command="systemctl default" ${key}'')
      config.users.users.fuji.openssh.authorizedKeys.keys;
  };

  services.openssh = {
    enable = true;
    openFirewall = false;
    # Logins are granted only by lib/admin-ssh-keys.nix, never by hand.
    authorizedKeysInHomedir = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "fuji" ];
    };
  };
  networking.firewall.interfaces.eno1.allowedTCPPorts = [
    22
    80
    443
    8443
  ];

  # Pods need to reach the Kubernetes API, including through the
  # kubernetes.default ClusterIP. Keep access limited to the API rather than
  # trusting the CNI interfaces and exposing every host service to workloads.
  networking.firewall.interfaces.cni0.allowedTCPPorts = [ 6443 ];
  networking.firewall.interfaces.flannel-wg.allowedTCPPorts = [ 6443 ];

  # Flannel uses the node external addresses on Tailscale for its native
  # WireGuard overlay. IPv4 pod networking uses UDP/51820 between nodes.
  networking.firewall.interfaces.tailscale0.allowedUDPPorts = [ 51820 ];

  # For not having to add ports to *.infra URLs
  # The edge is the exception: it passes public traffic through to Traefik
  # here, so its 443 must reach Traefik, not the private proxy.
  systemd.services.tailnet-https = {
    description = "Forward tailnet HTTPS to the private proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "firewall.service" ];
    before = [ "k3s.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "-${pkgs.nftables}/bin/nft delete table ip tailnet_https";
    };

    script = ''
      ${pkgs.nftables}/bin/nft -f - <<'EOF'
      add table ip tailnet_https
      flush table ip tailnet_https
      table ip tailnet_https {
        chain prerouting {
          type nat hook prerouting priority -110; policy accept;
          iifname "tailscale0" ip saddr != 100.64.0.9 ip daddr 100.64.0.1 tcp dport 443 counter dnat to 100.64.0.1:8443
        }
      }
      EOF
    '';
  };

  # Locale ------------------------------------------------------------------
  time.timeZone = "Europe/Bucharest";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ro_RO.UTF-8";
    LC_IDENTIFICATION = "ro_RO.UTF-8";
    LC_MEASUREMENT = "ro_RO.UTF-8";
    LC_MONETARY = "ro_RO.UTF-8";
    LC_NAME = "ro_RO.UTF-8";
    LC_NUMERIC = "ro_RO.UTF-8";
    LC_PAPER = "ro_RO.UTF-8";
    LC_TELEPHONE = "ro_RO.UTF-8";
    LC_TIME = "ro_RO.UTF-8";
  };
  services.xserver.xkb = { layout = "us"; variant = ""; };

  # Users -----------------------------------------------------------------
  users.users.fuji = {
    isNormalUser = true;
    description = "fuji";
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = builtins.attrValues (import ../../lib/admin-ssh-keys.nix);
  };

  # Sys packages ----------------------------------------------------------
  environment.systemPackages = with pkgs; [
    git
    vim
    wget
    claude-code
    age
    sops
    borgbackup
    sqlite
    codex
  ];

  # Kubernetes ------------------------------------------------------------
  services.k3s = {
    enable = true;
    role = "server";

    extraFlags = [
      "--node-external-ip=100.64.0.1"
      "--advertise-address=192.168.100.136"
      "--egress-selector-mode=disabled"
      "--flannel-backend=wireguard-native"
      "--flannel-external-ip"
    ];
  };

  systemd.tmpfiles.rules = [
    "v /var/lib/rancher/k3s/storage 0700 root root -"
    "d /var/lib/rancher/k3s/backup-staging 0700 root root -"
  ];

  # sops -------------------------------------------------------------------
  sops.age.keyFile = "/var/lib/sops-nix/key.txt";

  sops.defaultSopsFile = ../../secrets/fuji.yaml;

  # borg backup private ssh key
  sops.secrets.borg_ssh_private_key = {
    owner = "root";
    mode = "0400";
  };

  sops.secrets.borg_repo_passphrase = {
    owner = "root";
    mode = "0400";
  };

  # k3s server token
  sops.secrets.k3s_server_token = {
    owner = "root";
    mode = "0400";
  };

  sops.secrets.nut_upsmon_password = {
    owner = "root";
    mode = "0400";
  };

  services.k3s.tokenFile = "/run/secrets/k3s_server_token";

  # M4 ssh key -------------------------------------------------------------
  programs.ssh.knownHosts."m4-borg" = {
    hostNames = [ "100.64.0.3" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGMOJiwYgSQmZiK1qEAueUK1DWUruOa0yByKkOgzfwu";
  };

  # borg backup setup ------------------------------------------------------
    services.borgbackup.jobs.k3s = {
    paths = [
      "/var/lib/rancher/k3s/backup-staging/storage"
      "/var/lib/rancher/k3s/backup-staging/state.db"
      # hostPath data for Keycloak and Baikal, which isn't in a k3s volume.
      # Keycloak's Postgres is copied live, so this is crash-consistent only;
      # proper dumps come with CNPG (infrastructure #32).
      "/home/fuji/services"
      # Archives of retired machines (Komodo, the OVH VPS).
      "/home/fuji/migration-safety"
    ];

    repo = "ssh://borgworker@100.64.0.3/Volumes/Expansion/borg_repos/fuji-k3s";

    # Existing repository: never initialize/replace it.
    doInit = false;

    # We'll enable the timer after the manual test.
    startAt = "03:30";
    persistentTimer = true;

    prune.keep = {
      daily = 7;
      weekly = 4;
      monthly = 6;
    };

    archiveBaseName = "FUJI---K3s";
    compression = "zlib";

    # Only relevant when initializing a repo; ours already exists and is repokey-encrypted.
    encryption = {
      mode = "repokey";
      passCommand = "cat /run/secrets/borg_repo_passphrase";
    };

    environment.BORG_RSH =
      "ssh -i /run/secrets/borg_ssh_private_key -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes";

    extraArgs = [
      "--remote-path=/opt/homebrew/bin/borg"
    ];

    extraCreateArgs = [
      "--stats"
    ];

    readWritePaths = [
      "/var/lib/rancher/k3s/backup-staging"
    ];

    preHook = ''
      staging="/var/lib/rancher/k3s/backup-staging"

      if ${pkgs.btrfs-progs}/bin/btrfs subvolume show "$staging/storage" >/dev/null 2>&1; then
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$staging/storage"
      fi

      ${pkgs.coreutils}/bin/rm -f "$staging/state.db"

      ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot -r \
        /var/lib/rancher/k3s/storage \
        "$staging/storage"

      ${pkgs.sqlite}/bin/sqlite3 -batch \
        /var/lib/rancher/k3s/server/db/state.db \
        ".backup '$staging/state.db'"

      ${pkgs.sqlite}/bin/sqlite3 -batch -noheader -list \
        "$staging/state.db" \
        'PRAGMA integrity_check;' \
        | ${pkgs.gnugrep}/bin/grep -qx ok
    '';

    postHook = ''
      staging="/var/lib/rancher/k3s/backup-staging"

      if ${pkgs.btrfs-progs}/bin/btrfs subvolume show "$staging/storage" >/dev/null 2>&1; then
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$staging/storage"
      fi

      ${pkgs.coreutils}/bin/rm -f "$staging/state.db"
    '';
  };

  # UPS -------------------------------------------------------------------
  power.ups = {
    enable = true;
    mode = "standalone";

    ups.cyberpower = {
      driver = "usbhid-ups";
      port = "auto";
      description = "CyberPower CP900EPFCLCD";

      directives = [
        "vendorid = 0764"
        "productid = 0501"
        "serial = CX7RQ2000038"

        # Treat either <30% charge or <5 min runtime as low battery.
        "ignorelb"
        "override.battery.charge.low = 30"
        "override.battery.runtime.low = 300"
      ];
    };

    users.upsmon = {
      passwordFile = config.sops.secrets.nut_upsmon_password.path;
      upsmon = "primary";
    };

    upsmon = {
      enable = true;

      monitor.cyberpower = {
        system = "cyberpower@localhost";
        powerValue = 1;
        user = "upsmon";
        type = "primary";
      };
    };
  };

  # Keep the version from the machine's original installation. Changing it
  # can alter defaults for stateful services and data formats.
  system.stateVersion = "26.05";
}
