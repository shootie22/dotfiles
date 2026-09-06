# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  # Pull a few packages from the nixos-unstable channel while keeping the same
  # nixpkgs config/overlays as the stable `pkgs`.
  unstable = import <nixos-unstable> {
    inherit (pkgs) overlays config;
    system = pkgs.stdenv.hostPlatform.system;
  };
  # Noctalia pinned to v5 from its flake: nixos-unstable is still on 4.7.x,
  # which uses the old settings.json format and can't read our v5
  # ~/.local/state/noctalia/settings.toml. Switch to unstable.noctalia-shell
  # (and delete this pin) once the channel reaches >= 5.0.0.
  noctalia = (builtins.getFlake
    "github:noctalia-dev/noctalia/81f2c83d8e06d8d0398b0a268dc7e19766a9213f")
    .packages.${pkgs.stdenv.hostPlatform.system}.default;
  xmm7360Pci = pkgs.callPackage ../../pkgs/xmm7360-pci {
    kernel = config.boot.kernelPackages.kernel;
  };
  xmm7360RuntimeInputs = with pkgs; [
    coreutils
    gawk
    gnugrep
    gnused
    iproute2
    iputils
    kmod
    networkmanager
    openresolv
    pciutils
    procps
    systemd
  ];
  lteWrapperRuntimeInputs = xmm7360RuntimeInputs ++ [
    pkgs.curl
    pkgs.jq
    pkgs.sudo
    xmm7360HardReset
    xmm7360Status
    xmm7360UseLte
    xmm7360UseWifi
  ];
  xmm7360Helper = name: script: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = xmm7360RuntimeInputs;
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source ${./xmm7360/common.sh}
      ${builtins.readFile script}
    '';
  };
  xmm7360HardReset = xmm7360Helper "xmm7360-hard-reset" ./xmm7360/hard-reset.sh;
  xmm7360Reset = xmm7360Helper "xmm7360-reset" ./xmm7360/reset.sh;
  xmm7360Status = xmm7360Helper "xmm7360-status" ./xmm7360/status.sh;
  xmm7360UseDns = xmm7360Helper "xmm7360-use-dns" ./xmm7360/use-dns.sh;
  xmm7360UseLte = xmm7360Helper "xmm7360-use-lte" ./xmm7360/use-lte.sh;
  xmm7360UseWifi = xmm7360Helper "xmm7360-use-wifi" ./xmm7360/use-wifi.sh;
  lteWrapper = name: script: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = lteWrapperRuntimeInputs;
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      source ${./xmm7360/common.sh}
      ${builtins.readFile script}
    '';
  };
  lteOn = lteWrapper "lte-on" ./xmm7360/lte-on.sh;
  lteOff = lteWrapper "lte-off" ./xmm7360/lte-off.sh;
in
{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix

      # Home Manager
      <home-manager/nixos>

      # Shared modules (see ../../modules/nixos/)
      ../../modules/nixos/common.nix
      ../../modules/nixos/desktop-hyprland.nix
      ../../modules/nixos/gaming.nix
      ../../modules/nixos/docker.nix
    ];

  # Makes `unstable`/`noctalia` available to every imported NixOS module
  # (home-manager modules get them separately via extraSpecialArgs below).
  _module.args = {
    inherit unstable noctalia;
  };

  modules.gaming.enable = true;
  modules.docker.enable = true;

  home-manager.extraSpecialArgs = {
    inherit unstable;
  };

  home-manager.users.bro = import ../../home/bro/hosts/nixpad.nix;

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.luks.devices."luks-d42cecf7-c82c-4396-83d7-20a1b651a281".device = "/dev/disk/by-uuid/d42cecf7-c82c-4396-83d7-20a1b651a281";
  networking.hostName = "nixpad";
  #networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Disable ModemManager for the internal XMM7360: the card is in unsupported
  # RPC mode, and the experimental driver/scripts bypass ModemManager.
  networking.modemmanager.enable = false;

  # Experimental support for the Fibocom L850-GL / Intel XMM7360.
  # ModemManager rejects this card in RPC mode, so keep iosm off and test the
  # out-of-tree module manually with `xmm7360-connect`.
  boot.blacklistedKernelModules = [ "iosm" ];
  boot.kernelModules = [ "acpi_call" ];
  boot.extraModulePackages = [
    xmm7360Pci
    config.boot.kernelPackages.acpi_call
  ];

  # Set your time zone.
  time.timeZone = "Europe/Copenhagen";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_DK.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "da_DK.UTF-8";
    LC_IDENTIFICATION = "da_DK.UTF-8";
    LC_MEASUREMENT = "da_DK.UTF-8";
    LC_MONETARY = "da_DK.UTF-8";
    LC_NAME = "da_DK.UTF-8";
    LC_NUMERIC = "da_DK.UTF-8";
    LC_PAPER = "da_DK.UTF-8";
    LC_TELEPHONE = "da_DK.UTF-8";
    LC_TIME = "da_DK.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "dk,us";
    variant = ",";
    options = "grp:win_space_toggle";
  };

  # Configure console keymap
  console.keyMap = "dk-latin1";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.bro = {
    isNormalUser = true;
    description = "bro";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [

  # Mobile broadband
  usbutils
  lteOn
  lteOff
  xmm7360Pci
  xmm7360HardReset
  xmm7360Reset
  xmm7360Status
  xmm7360UseLte
  xmm7360UseDns
  xmm7360UseWifi
  mobile-broadband-provider-info
  libmbim
  libqmi

  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # Services

  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 90;
      STOP_CHARGE_THRESH_BAT0 = 95;
    };
  };

  environment.etc."xmm7360.example".text = ''
    # Copy this to /etc/xmm7360 and set your carrier APN before starting
    # xmm7360-connect.service.
    apn=your.apn.here

    # Optional: keep Wi-Fi preferred when both are up.
    metric=1000

    # Optional: do not append DNS servers to /etc/resolv.conf.
    #noresolv=True
  '';

  systemd.services.xmm7360-connect = {
    description = "Connect the experimental XMM7360 LTE modem";
    after = [ "network.target" ];
    restartIfChanged = false;
    path = with pkgs; [ coreutils gawk gnugrep kmod openresolv iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "90s";
      TimeoutStopSec = "15s";
    };
    script = ''
      if ! grep -q '^apn=.*[^[:space:]]' /etc/xmm7360 2>/dev/null; then
        echo "Create /etc/xmm7360 from /etc/xmm7360.example and set apn=..."
        exit 1
      fi

      modprobe -r iosm || true
      if ! lsmod | grep -q '^xmm7360 '; then
        modprobe xmm7360 || insmod ${xmm7360Pci}/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/extra/xmm7360.ko
      fi
      ${xmm7360Pci}/bin/xmm7360-connect --nodefaultroute --noresolv -c /etc/xmm7360
    '';
    postStop = ''
      ip route del default dev wwan0 2>/dev/null || true
      ip_addr="$(ip -4 -o addr show dev wwan0 scope global | awk '{ split($4, a, "/"); print a[1]; exit }')"
      if [ -n "$ip_addr" ]; then
        ip route del default via "$ip_addr" dev wwan0 2>/dev/null || true
      fi
    '';
  };

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
