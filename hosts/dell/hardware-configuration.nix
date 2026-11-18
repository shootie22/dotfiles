# Dell PowerEdge T30 (Xeon E3, 32 GB), in DK. The system disk is disko.nix;
# this is the rest of the hardware. Written before the machine was installed:
# check it against `nixos-generate-config --show-hardware-config` on the
# installer and adjust anything that differs.
{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disko.nix
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    # Not there yet: so a system disk swapped for an NVMe boots as it is.
    "nvme"
    "usb_storage"
    "usbhid"
    "sd_mod"
    # The onboard I219-LM, for unlocking over the network.
    "e1000e"
  ];
  boot.kernelModules = [ "kvm-intel" ];

  # The 4 TB disk (storage-disk.nix made it), found by its partition label
  # and opened once the system is up, with its keyfile from SOPS. nofail: if
  # it's missing or dead the machine still boots and stays reachable. Nothing
  # uses it yet; it's there for the cluster's bulk data when something needs
  # it.
  environment.etc.crypttab.text = ''
    storage /dev/disk/by-partlabel/disk-storage-luks ${config.sops.secrets.dell_storage_key.path} luks,nofail
  '';
  fileSystems."/srv/storage" = {
    device = "/dev/mapper/storage";
    fsType = "ext4";
    options = [ "nofail" "noatime" ];
  };

  # No swap volume; compressed RAM instead, like the thinkcentre.
  zramSwap.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
