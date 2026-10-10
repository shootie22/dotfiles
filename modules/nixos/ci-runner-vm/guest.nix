# The CI runner VM: boots, runs exactly one Gitea Actions job with Docker,
# and powers off. Nothing in it survives: the root is a tmpfs, the store is a
# read-only image of this closure (not the host's /nix/store), and the host
# recreates the Docker disk before every boot.
#
# The host registers the runner and puts only the resulting .runner file
# (credentials Gitea revokes once the job is assigned) on the read-only
# ci-host share. The registration token never enters the VM.
{ cfg, inputs, system }:

inputs.nixpkgs-nixpad.lib.nixosSystem {
  inherit system;
  modules = [
    inputs.microvm.nixosModules.microvm
    ({ lib, pkgs, ... }:
      let
        runnerConfig = (pkgs.formats.yaml { }).generate "gitea-runner.yaml" {
          log.level = "info";
          runner = {
            file = "/var/lib/gitea-runner/.runner";
            capacity = 1;
            timeout = "3h";
          };
          cache = {
            enabled = true;
            dir = "/var/lib/docker/runner-cache";
          };
          container = {
            # No host paths from workflows; jobs get this VM's Docker socket
            # (root in a throwaway VM), never the workstation's.
            valid_volumes = [ ];
            privileged = false;
          };
        };
      in
      {
        networking = {
          hostName = "ci-runner";
          useDHCP = false;
          useNetworkd = true;
          # Isolation is on the host (passt runs as ci-vm, which nftables keeps
          # to the public internet); a guest firewall would add nothing.
          firewall.enable = false;
          nameservers = [ "1.1.1.1" "9.9.9.9" ];
        };
        services.resolved.enable = false;
        systemd.network = {
          enable = true;
          wait-online.enable = false;
          networks."10-uplink" = {
            # By name: Type = ether would also take Docker's veths and pull
            # them off its bridges.
            matchConfig.Name = "enp*";
            networkConfig.DHCP = "ipv4";
            dhcpV4Config = {
              UseDNS = false;
              UseDomains = false;
            };
          };
        };

        boot.kernelParams = [ "quiet" ];
        services.timesyncd.enable = false;
        services.logrotate.enable = false;
        services.udisks2.enable = false;
        documentation.enable = false;
        systemd.oomd.enable = false;

        # Nobody logs in: no sshd, no getty, no root password.
        users.mutableUsers = false;
        users.allowNoPasswordLogin = true;
        systemd.services."serial-getty@ttyS0".enable = false;
        systemd.services."autovt@".enable = false;
        security.sudo.enable = false;

        virtualisation.docker = {
          enable = true;
          daemon.settings = {
            data-root = "/var/lib/docker";
            # Docker Hub rate-limits anonymous pulls; Google's mirror first.
            registry-mirrors = [ "https://mirror.gcr.io" ];
          };
        };

        systemd.services.gitea-runner = {
          description = "One Gitea Actions job, then power off";
          wantedBy = [ "multi-user.target" ];
          after = [ "docker.service" "network-online.target" ];
          wants = [ "docker.service" "network-online.target" ];
          path = [ pkgs.git pkgs.nodejs pkgs.docker pkgs.bash pkgs.coreutils ];
          environment.HOME = "/var/lib/gitea-runner";
          serviceConfig = {
            Type = "oneshot";
            StateDirectory = "gitea-runner";
            # Power off however the job ends (or if it never starts).
            ExecStopPost = "${pkgs.systemd}/bin/systemctl --no-block poweroff";
          };
          script = ''
            install -m 0600 /run/ci-host/.runner /var/lib/gitea-runner/.runner
            cd /var/lib/gitea-runner
            exec ${lib.getExe' pkgs.gitea-actions-runner "gitea-runner"} daemon --once --config ${runnerConfig}
          '';
        };

        microvm = {
          hypervisor = "qemu";
          vcpu = cfg.cpus;
          mem = cfg.memoryMB;
          optimize.enable = true;
          qemu.serialConsole = true;
          # The closure as a read-only disk image, so the VM never sees the
          # host's /nix/store.
          storeOnDisk = true;
          interfaces = [ ];
          # The network goes through the host's passt socket (see default.nix).
          extraArgsScript = toString (pkgs.writeShellScript "ci-vm-qemu-net" ''
            echo "-netdev stream,id=net0,server=off,addr.type=unix,addr.path=/run/ci-vm-net/passt.sock -device virtio-net-pci,netdev=net0,mac=02:00:00:00:00:02,romfile="
          '');
          shares = [{
            tag = "ci-host";
            source = "/var/lib/ci-vm/share";
            mountPoint = "/run/ci-host";
            proto = "9p";
            securityModel = "none";
            readOnly = true;
          }];
          volumes = [{
            # The host deletes it before every boot.
            image = "/var/lib/ci-vm/docker.img";
            mountPoint = "/var/lib/docker";
            size = cfg.dockerDiskMB;
            fsType = "ext4";
            autoCreate = true;
          }];
        };

        system.stateVersion = "26.05";
      })
  ];
}
