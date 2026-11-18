# dell's system disk, applied by nixos-anywhere on every install
# (hosts/dell/install). Whatever disk disks.nix names (the 240 GB SATA SSD
# today) gets:
#
#   GPT: 1 GB ESP, then LUKS (passphrase, unlocked over SSH in the initrd)
#   with LVM inside:
#     root     60 GB ext4   /: the OS and the Nix store
#     rancher  the rest     /var/lib/rancher: containerd's images, local-path
#                           volumes, CI jobs' scratch
#   Two volumes so a CI job can only fill its own, never / (the thinkcentre's
#   disk pressure, infrastructure incident 2026-10-20). `rancher` takes what's
#   left, so a bigger disk needs no change here.
#
# The 4 TB disk is not in here on purpose (storage-disk.nix): a reinstall
# wipes what this file describes and nothing else.
#
# The install script hands disko the passphrase in /tmp; it isn't kept on the
# machine.
{ ... }:

{
  disko.devices = {
    disk.system = {
      type = "disk";
      device = (import ./disks.nix).system;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            priority = 1;
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              # The initrd files here carry the unlock host key and the
              # edge tunnel key.
              mountOptions = [ "fmask=0077" "dmask=0077" ];
            };
          };
          crypt = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              passwordFile = "/tmp/dell-root.pass";
              settings = {
                # For the weekly fstrim; the filesystems aren't mounted with
                # `discard`, which stalls SATA disks without queued TRIM.
                allowDiscards = true;
                # Encrypt in the caller instead of queueing every request for
                # dm-crypt's worker threads: on an SSD the queues only add
                # latency, most of all while the disk is busy writing.
                bypassWorkqueues = true;
              };
              content = {
                type = "lvm_pv";
                vg = "dell-vg";
              };
            };
          };
        };
      };
    };

    lvm_vg."dell-vg" = {
      type = "lvm_vg";
      lvs = {
        root = {
          size = "60G";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            # LVM on LUKS: wait as long as the unlock takes (mixi, 2026-10-03).
            mountOptions = [ "x-systemd.device-timeout=infinity" ];
          };
        };
        # Created last, takes what's left.
        rancher = {
          size = "100%FREE";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var/lib/rancher";
            mountOptions = [ "nofail" "noatime" ];
          };
        };
      };
    };
  };
}
