# Rehearsal VM for the thinkcentre's move to NixOS (infrastructure #18).
# Same disk layout (scaled down), same boot safety module, a fake Debian at
# Debian's shim path, and run.py to boot it through every failure scenario
# in QEMU with UEFI firmware. Only the timeouts are shorter.
#
#   nix build .#nixosConfigurations.thinkcentre-rehearsal.config.system.build.diskoImages
#   python3 run.py --image result/nvme.qcow2 ...   (see run.py)
{
  config,
  lib,
  pkgs,
  modulesPath,
  extendModules,
  ...
}:

let
  cfg = config.rehearsal;
  # The same system with the boot health check pointed at an address that
  # never answers: a generation that boots but counts as unreachable.
  # Throwaway keys for unlocking the VM over SSH, like the real machine. They
  # only exist in the rehearsal's store paths and open nothing else.
  testKeys = pkgs.runCommand "rehearsal-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir $out
    ssh-keygen -q -t ed25519 -N "" -C rehearsal-initrd -f $out/initrd_host_ed25519_key
    ssh-keygen -q -t ed25519 -N "" -C rehearsal-client -f $out/client_ed25519
  '';
  broken = (extendModules {
    modules = [
      {
        rehearsal.broken = true;
        dotfiles.bootSafety.gateway = lib.mkForce "10.9.9.9";
      }
    ];
  }).config.system.build.toplevel;
in
{
  imports = [
    ../boot-safety.nix
    ../../../modules/nixos/initrd-dhcp-handover.nix
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  options.rehearsal.broken = lib.mkEnableOption "the deliberately broken generation";

  config = {
    disko.devices = lib.recursiveUpdate (import ../disko-layout.nix {
      inherit lib;
      device = "/dev/vda";
      espSize = "512M";
      spareSize = "64M";
      homeSize = "1G";
      debianRootSize = "1G";
      passwordFile = "${pkgs.writeText "rehearsal-luks-password" "test"}";
    }) { disk.nvme.imageSize = "10G"; };
    disko.imageBuilder.imageFormat = "qcow2";
    # disko 725ea35 hands vmTools an aggregateModules package, which newer
    # nixpkgs rejects for lacking `target`. The bzImage is in it anyway.
    disko.imageBuilder.pkgs = pkgs.extend (final: prev: {
      aggregateModules = mods: (prev.aggregateModules mods) // { target = "bzImage"; };
    });

    networking.hostName = "thinkcentre-rehearsal";
    system.stateVersion = "26.11";

    dotfiles.bootSafety = {
      gateway = "10.0.2.2"; # QEMU user networking
      unlockTimeout = "2min";
      healthChecks = 6;
    };

    boot.kernelParams = [ "console=ttyS0,115200" ];
    boot.loader.timeout = 1;
    boot.loader.systemd-boot.extraFiles."EFI/debian/shimx64.efi" = pkgs.callPackage ./fake-debian.nix { };

    # Network like the thinkcentre: DHCP in the initrd, NetworkManager after.
    boot.initrd.systemd.enable = true;
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" ];
    boot.initrd.systemd.network = {
      enable = true;
      networks."10-lan" = {
        matchConfig.Name = "enp0s3";
        networkConfig.DHCP = "ipv4";
        dhcpV4Config.ClientIdentifier = "mac";
        linkConfig.RequiredForOnline = "no";
      };
    };
    dotfiles.lanInterface = "enp0s3";
    # Unlock over SSH in the initrd, as on the real machine (port 2222).
    boot.initrd.network.ssh = {
      enable = true;
      port = 2222;
      # NixOS rejects store paths for host keys (they'd be world-readable).
      # Fine for a throwaway key in a VM; the key itself goes into the image
      # through extraDependencies below.
      hostKeys = [ (builtins.unsafeDiscardStringContext "${testKeys}/initrd_host_ed25519_key") ];
      authorizedKeys = [ (builtins.readFile "${testKeys}/client_ed25519.pub") ];
    };
    # For run.py: where the client key is.
    system.build.rehearsalKeys = testKeys;
    networking.networkmanager.enable = true;
    services.openssh.enable = true;

    # The harness drives the VM over the serial console.
    services.getty.autologinUser = "root";

    # The 4 TB disk missing, and k3s waiting for it: every boot has to reach
    # multi-user with sshd up and this service not started.
    environment.etc.crypttab.text = ''
      storage UUID=00000000-0000-0000-0000-000000000000 /run/no-such-key luks,nofail
    '';
    fileSystems."/home/main/storage" = {
      device = "/dev/mapper/storage";
      fsType = "ext4";
      options = [ "nofail" ];
    };
    systemd.services.fake-k3s = {
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ "/home" "/home/main/storage" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
      };
    };

    environment.systemPackages = [ pkgs.efibootmgr ] ++ lib.optionals (!cfg.broken) [
      # Makes the broken system the default boot entry, like comin deploying
      # a bad commit after the trial.
      (pkgs.writeShellScriptBin "deploy-broken" ''
        set -e
        nix-env -p /nix/var/nix/profiles/system --set ${broken}
        ${broken}/bin/switch-to-configuration boot
      '')
    ];
    system.extraDependencies = [ testKeys ] ++ lib.optionals (!cfg.broken) [ broken ];
  };
}
