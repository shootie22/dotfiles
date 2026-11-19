# Which device is which on dell. Only read at install time (disko.nix,
# storage-disk.nix, the install script): the running system finds everything
# by label, so these names can be wrong afterwards without anything breaking.
#
# Swapping the system disk (say, for an NVMe): change `system`, commit,
# hosts/dell/install. Nothing else in the config knows what kind of disk it is.
{
  # The system disk: the 240 GB SATA SSD today. An NVMe is /dev/nvme0n1.
  system = "/dev/sda";
  # The 4 TB HDD. Only used by `install --format-storage`, the first time.
  storage = "/dev/sdb";
}
