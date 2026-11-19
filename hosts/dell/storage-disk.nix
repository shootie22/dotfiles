# dell's 4 TB disk as disko makes it: GPT with one partition, LUKS with the
# keyfile from secrets/dell-storage-key.bin, ext4. Only part of the layout
# for `hosts/dell/install --format-storage` (the first install, or a new
# HDD); the flake builds that disko script as packages.dell-disko-with-storage.
# Every other install leaves the disk alone.
#
# No mountpoint here: the mount and the crypttab line are in
# hardware-configuration.nix, by label, so the system is the same with or
# without this file. The partition label disko gives it (disk-storage-luks)
# is what they look for.
{ ... }:

{
  disko.devices.disk.storage = {
    type = "disk";
    device = (import ./disks.nix).storage;
    content = {
      type = "gpt";
      partitions.luks = {
        size = "100%";
        content = {
          type = "luks";
          name = "storage";
          # Opened after boot by crypttab, never in the initrd.
          initrdUnlock = false;
          settings.keyFile = "/tmp/dell-storage.key";
          content = {
            type = "filesystem";
            format = "ext4";
          };
        };
      };
    };
  };
}
