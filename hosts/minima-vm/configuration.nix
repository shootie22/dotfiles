{ lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  networking.hostName = "minima-k3s";

  # Lima creates/manages the login user at boot.
  users.mutableUsers = true;
  services.lima.enable = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.openssh.enable = true;
  security.sudo.wheelNeedsPassword = false;

  # Match the nixos-lima disk image layout.
  boot.loader.grub = {
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
  };

  fileSystems."/boot" = {
    device = lib.mkForce "/dev/vda1";
    fsType = "vfat";
  };

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
    options = [ "noatime" "nodiratime" "discard" ];
  };

  # Apple Silicon hosts use 16 KiB pages. Venus/krunkit needs the
  # guest to use 16 KiB pages too for GPU blob mappings.
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelPatches = [
    {
      name = "arm64-16k-pages";
      patch = null;
      structuredExtraConfig = with lib.kernel; {
        ARM64_4K_PAGES = lib.mkForce no;
        ARM64_16K_PAGES = lib.mkForce yes;
        ARM64_64K_PAGES = lib.mkForce no;
        ARM64_VA_BITS_47 = lib.mkForce yes;
      };
    }
  ];

  # Mesa includes the Venus virtio-gpu Vulkan driver.
  hardware.graphics.enable = true;

  environment.systemPackages = with pkgs; [
    gitMinimal
    vulkan-tools
  ];

  system.stateVersion = "26.05";
}
