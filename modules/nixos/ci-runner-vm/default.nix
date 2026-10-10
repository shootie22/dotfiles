# A Gitea Actions runner in a throwaway VM, for machines outside the cluster
# (the workstation). It helps with the queue while the machine is on; jobs
# from any repo, friends' included, can land here, so:
# - Every job gets a fresh VM (guest.nix): one job, then it powers off and
#   the next boot starts from scratch, Docker disk included.
# - The host registers an ephemeral runner for each boot. The registration
#   token stays in a root-only file; the VM gets only the one-job credentials,
#   which Gitea revokes once the job is assigned.
# - QEMU runs as ci-vm, sandboxed by systemd (no /home, read-only system),
#   and the VM's traffic leaves through passt, also as ci-vm, which nftables
#   keeps to the public internet: no LAN, tailnet, local services or IPv6.
# - CPU and I/O weights well below the desktop's, so builds use what's idle.
#
# Turning the machine off mid-job fails that job; run it again in Gitea.
# Set the token with `sudo ci-runner-vm-set-token` (the instance token is in
# the infrastructure repo, kubernetes/services/ci-runner/secret.sops.yaml).
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.dotfiles.ciRunnerVm;
  system = pkgs.stdenv.hostPlatform.system;
  guest = import ./guest.nix { inherit cfg inputs system; };
  vm = guest.config.microvm.declaredRunner;
  ctl = "/var/lib/ci-vm-ctl";
  state = "/var/lib/ci-vm";

  labels = lib.concatMapStringsSep "," (l: "${l}:docker://docker.gitea.com/runner-images:ubuntu-latest") cfg.labels;

  registerConfig = (pkgs.formats.yaml { }).generate "register.yaml" {
    runner.file = "${state}/share/.runner";
  };

  egressRules = pkgs.writeText "ci-vm.nft" ''
    table inet ci_vm {
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid != "ci-vm" accept
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

  # Root: fresh state, then an ephemeral registration for this boot.
  prepare = pkgs.writeShellScript "ci-vm-prepare" ''
    set -eu
    if [ ! -s ${ctl}/token ]; then
      echo "no registration token yet: sudo ci-runner-vm-set-token" >&2
      exit 1
    fi
    find ${state} -mindepth 1 -delete
    install -d -m 0750 -o ci-vm -g ci-vm ${state}/share
    ${lib.getExe' pkgs.gitea-actions-runner "gitea-runner"} register --no-interactive --ephemeral \
      --config ${registerConfig} --instance https://git.radunenu.com \
      --token-file ${ctl}/token --name ${config.networking.hostName} --labels ${labels}
    chown ci-vm:ci-vm ${state}/share/.runner
    chmod 0400 ${state}/share/.runner
  '';

  setToken = pkgs.writeShellScriptBin "ci-runner-vm-set-token" ''
    set -eu
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
    read -rsp "Runner registration token: " token; echo
    umask 077
    printf '%s\n' "$token" > ${ctl}/token
    systemctl restart ci-runner-vm.service
    echo "Saved; the runner VM is starting."
  '';
in
{
  options.dotfiles.ciRunnerVm = {
    enable = lib.mkEnableOption "a Gitea Actions runner in a throwaway VM";
    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Virtual CPUs of the runner VM.";
    };
    memoryMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12288;
      description = "RAM of the runner VM in MiB.";
    };
    dockerDiskMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = "Size of the VM's Docker disk in MiB (sparse, recreated per job).";
    };
    labels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "linux-amd64" "linux-amd64-${config.networking.hostName}" ];
      description = "runs-on labels; each runs in the runner-images Ubuntu image.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.ci-vm = {
      isSystemUser = true;
      group = "ci-vm";
      extraGroups = [ "kvm" ];
      description = "Gitea Actions runner VM";
    };
    users.groups.ci-vm = { };

    environment.systemPackages = [ setToken ];

    systemd.tmpfiles.rules = [
      "d ${ctl} 0700 root root -"
      "d ${state} 0750 ci-vm ci-vm -"
    ];

    systemd.services.ci-vm-egress = {
      description = "Keep the CI runner VM's traffic to the public internet";
      unitConfig.DefaultDependencies = false;
      wantedBy = [ "sockets.target" ];
      before = [ "ci-vm-net.socket" "sockets.target" "shutdown.target" ];
      conflicts = [ "shutdown.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "-${pkgs.nftables}/bin/nft delete table inet ci_vm";
        ExecStart = "${pkgs.nftables}/bin/nft -f ${egressRules}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table inet ci_vm";
      };
    };

    systemd.sockets.ci-vm-net = {
      description = "Network backend socket for the CI runner VM";
      wantedBy = [ "sockets.target" ];
      requires = [ "ci-vm-egress.service" ];
      after = [ "ci-vm-egress.service" ];
      socketConfig = {
        ListenStream = "/run/ci-vm-net/passt.sock";
        Accept = true;
        SocketMode = "0660";
        SocketUser = "ci-vm";
        SocketGroup = "ci-vm";
      };
    };

    systemd.services."ci-vm-net@" = {
      description = "Network backend for the CI runner VM";
      requires = [ "ci-vm-egress.service" ];
      after = [ "ci-vm-egress.service" ];
      serviceConfig = {
        User = "ci-vm";
        Group = "ci-vm";
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

    systemd.services.ci-runner-vm = {
      description = "Gitea Actions runner VM (one job per boot)";
      # Waits quietly for a token instead of failing every 10 seconds;
      # ci-runner-vm-set-token starts it.
      unitConfig.ConditionPathExists = "${ctl}/token";
      wantedBy = [ "multi-user.target" ];
      requires = [ "ci-vm-net.socket" ];
      after = [ "network-online.target" "ci-vm-net.socket" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "ci-vm";
        Group = "ci-vm";
        ExecStartPre = "+${prepare}";
        ExecStart = "${vm}/bin/microvm-run";
        WorkingDirectory = state;
        Restart = "always";
        RestartSec = 10;
        # The desktop comes first.
        CPUWeight = 20;
        IOWeight = 20;
        MemoryMax = "${toString (cfg.memoryMB + 1024)}M";
        # If QEMU is ever escaped, this is what's left to see.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ state ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        DeviceAllow = [ "/dev/kvm rw" ];
        DevicePolicy = "closed";
      };
    };
  };
}
