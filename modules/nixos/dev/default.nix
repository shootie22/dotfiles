# Disposable development MicroVMs: `dev [command]` in any folder.
# guest.nix is the VM image; dev.sh is the launcher. This file is the host
# side: the confined network path for guests and the `dev` command itself.
# See README.md for usage and the threat model.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.modules.dev;
  system = pkgs.stdenv.hostPlatform.system;

  guest = import ./guest.nix { inherit cfg inputs system; };
  runner = guest.config.microvm.declaredRunner;

  # Everything the dev-net user (the guests' passt instances) may not reach:
  # this host, loopback, the LAN, Tailscale/CGNAT, link-local, Docker
  # networks, multicast/reserved space, and all of IPv6. A reject verdict in
  # any table is final, so this holds regardless of the iptables firewall.
  egressRules = pkgs.writeText "dev-net.nft" ''
    table inet dev_net {
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid != "dev-net" accept
        ct state established,related accept
        meta nfproto ipv6 reject
        fib daddr type local reject
        ip daddr {
          0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16,
          172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 198.18.0.0/15,
          224.0.0.0/4, 240.0.0.0/4
        } reject
      }
    }
  '';

  runtimeInputs = with pkgs; [
    coreutils
    findutils
    gawk
    git
    gnugrep
    gnused
    iproute2
    openssh
    procps
    socat
    util-linux
    virtiofsd
  ];

  dev = pkgs.writeShellScriptBin "dev" ''
    export PATH=${lib.makeBinPath runtimeInputs}:$PATH
    export DEV_RUNNER=${lib.escapeShellArg (toString runner)}
    exec ${pkgs.bash}/bin/bash ${./dev.sh} "$@"
  '';
in
{
  options.modules.dev = {
    enable = lib.mkEnableOption "disposable development MicroVMs";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Host user allowed to launch development MicroVMs.";
    };

    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Virtual CPUs per development MicroVM.";
    };

    memoryMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "RAM in MiB per development MicroVM.";
    };

    homeSizeMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8192;
      description = "Persistent per-project home volume size in MiB (sparse).";
    };

    storeOverlaySizeMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "Disposable writable Nix store overlay size in MiB (sparse).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "modules.dev.user must name an existing NixOS user";
      }
    ];

    environment.systemPackages = [ dev ];
    users.users.${cfg.user}.extraGroups = [ "kvm" ];

    users.users.dev-net = {
      isSystemUser = true;
      group = "dev-net";
      description = "Network backend for development MicroVMs";
    };
    users.groups.dev-net = { };

    systemd.services.dev-net-egress = {
      description = "Confine development MicroVM traffic to the public internet";
      wantedBy = [ "multi-user.target" ];
      before = [ "dev-net.socket" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "-${pkgs.nftables}/bin/nft delete table inet dev_net";
        ExecStart = "${pkgs.nftables}/bin/nft -f ${egressRules}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table inet dev_net";
      };
    };

    # Each VM connection gets its own passt, running as dev-net.
    systemd.sockets.dev-net = {
      description = "Network backend socket for development MicroVMs";
      wantedBy = [ "sockets.target" ];
      requires = [ "dev-net-egress.service" ];
      after = [ "dev-net-egress.service" ];
      socketConfig = {
        ListenStream = "/run/dev-net/passt.sock";
        Accept = true;
        SocketMode = "0660";
        SocketGroup = "kvm";
      };
    };

    systemd.services."dev-net@" = {
      description = "Network backend for a development MicroVM";
      requires = [ "dev-net-egress.service" ];
      after = [ "dev-net-egress.service" ];
      serviceConfig = {
        User = "dev-net";
        Group = "dev-net";
        # --no-map-gw: the gateway address does not lead to the host.
        # -F 3: the accepted connection from systemd.
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.passt}/bin/passt"
          "--foreground --one-off --fd 3"
          "--ipv4-only --no-map-gw"
          "--dns 1.1.1.1 --search none"
          "--tcp-ports none --udp-ports none"
        ];
        NoNewPrivileges = true;
      };
    };
  };
}
