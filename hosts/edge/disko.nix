# Disk layout for the edge VPS, applied by nixos-anywhere on install.
# GPT with both a BIOS boot partition and an ESP, so GRUB boots whether the
# provider's VM firmware is legacy BIOS (OVH) or UEFI. No encryption: the VPS
# holds no data worth protecting at rest, and nobody is there to unlock it.
{ device ? "/dev/sda", ... }:

{
  disko.devices.disk.main = {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };
        esp = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
