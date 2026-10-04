# The thinkcentre's NVMe as disko describes it: GPT with the ESP, Debian's
# old /boot (unused), and LUKS with LVM inside. Used by the rehearsal VM
# (rehearsal/) with small sizes, and by disko.nix for rebuilding the real disk
# from scratch. The live machine's mounts are in hardware-configuration.nix;
# disko is never run against it.
#
# debianRootSize: the Debian root volume that exists during the trial.
# passwordFile: only for test images; real disks ask for the passphrase.
{
  lib,
  device,
  espSize,
  spareSize,
  homeSize,
  debianRootSize ? null,
  passwordFile ? null,
}:

{
  disk.nvme = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          size = espSize;
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        # Debian's /boot partition. Kept so the layout matches the real disk.
        spare = {
          priority = 2;
          size = spareSize;
        };
        crypt = {
          priority = 3;
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            settings.allowDiscards = true;
            content = {
              type = "lvm_pv";
              vg = "thinkcentre-vg";
            };
          } // (if passwordFile != null then { inherit passwordFile; } else { askPassword = true; });
        };
      };
    };
  };

  lvm_vg."thinkcentre-vg" = {
    type = "lvm_vg";
    lvs = {
      home = {
        size = homeSize;
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/home";
          mountOptions = [ "nofail" ];
        };
      };
      # Created last, takes what's left.
      nixos = {
        size = "100%FREE";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
          # LVM on LUKS: wait as long as the unlock takes.
          mountOptions = [ "x-systemd.device-timeout=infinity" ];
        };
      };
    } // lib.optionalAttrs (debianRootSize != null) {
      root = {
        size = debianRootSize;
        content = {
          type = "filesystem";
          format = "ext4";
        };
      };
    };
  };
}
