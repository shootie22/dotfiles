# Lenovo ThinkCentre (i5-7400T, 32 GB). Written from the Debian install's
# layout (infrastructure #15) so the reinstall keeps every data volume:
#
#   NVMe p1   976 MB ESP          /boot (systemd-boot)
#   NVMe p2   977 MB ext4         Debian's old /boot, unused
#   NVMe p3   LUKS -> LVM thinkcentre-vg
#               root    31 GB, Debian, kept as the fallback during the trial
#               nixos   NixOS, made from the 24 GB swap volume; Debian's
#                       root gets merged into it once NixOS is the default
#               home    420 GB, kept as is: /home/main/services lives here
#   sdb       4 TB HDD, LUKS with a keyfile, kept as is: /home/main/storage
#
# The reinstall steps are in the infrastructure repo,
# docs/ha/runbooks/thinkcentre-reinstall.md.
{ config, lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "uas"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  boot.initrd.luks.devices.cryptroot = {
    device = "/dev/disk/by-uuid/ee73e8ce-52f8-44c5-bab1-0cac1592167f";
    allowDiscards = true;
  };

  fileSystems."/" = {
    device = "/dev/mapper/thinkcentre--vg-nixos";
    fsType = "ext4";
    # LVM on LUKS: the volume only appears after the unlock, which over SSH
    # can take longer than systemd's default 90 s (see mixi, 2026-10-03).
    options = [ "x-systemd.device-timeout=infinity" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/4A5A-55D9";
    fsType = "vfat";
    # The initrd files here carry the unlock host key and the tunnel key.
    options = [ "fmask=0077" "dmask=0077" ];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-uuid/da34737c-9612-4309-a43a-77bdbaded492";
    fsType = "ext4";
  };

  # The 4 TB disk opens in stage 2 with its keyfile (kept in SOPS, see
  # configuration.nix). nofail: if it doesn't open, the machine still boots
  # and stays reachable; Gitea then shows no repositories until it's fixed,
  # but nothing gets deleted.
  environment.etc.crypttab.text = ''
    tc-storage4tb UUID=3bc0b72c-b767-46a8-8420-8dbae9173c0a ${config.sops.secrets.tc_storage_key.path} luks,nofail
  '';

  fileSystems."/home/main/storage" = {
    device = "/dev/mapper/tc-storage4tb";
    fsType = "ext4";
    options = [ "nofail" ];
  };

  fileSystems."/home/main/services/gitea/git/repositories" = {
    device = "/home/main/storage/gitea_repos";
    fsType = "none";
    options = [ "bind" "nofail" ];
    depends = [ "/home/main/storage" ];
  };

  # k3s keeps containerd's images and layers here (15 GB on Debian, which is
  # what filled the old 31 GB root, #105). On /home there's room.
  fileSystems."/var/lib/rancher" = {
    device = "/home/rancher";
    fsType = "none";
    options = [ "bind" ];
    depends = [ "/home" ];
  };

  # No swap volume anymore (its space is the NixOS root); compressed RAM instead.
  zramSwap.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
