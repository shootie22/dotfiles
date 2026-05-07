# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

let
  # Pull a few packages from the nixos-unstable channel while keeping the same
  # nixpkgs config/overlays as the stable `pkgs`.
  unstable = import <nixos-unstable> {
    inherit (pkgs) system overlays config;
  };
  xmm7360Pci = pkgs.callPackage ../../pkgs/xmm7360-pci {
    kernel = config.boot.kernelPackages.kernel;
  };
  xmm7360Status = pkgs.writeShellScriptBin "xmm7360-status" ''
    set -eu

    echo "== service =="
    systemctl --no-pager --plain status xmm7360-connect || true

    echo
    echo "== driver =="
    lspci -nnk | grep -A4 -i xmm || true

    echo
    echo "== wwan0 =="
    ip addr show wwan0 || true

    echo
    echo "== wwan0 counters =="
    ip -s link show wwan0 || true

    echo
    echo "== routes =="
    ip route

    echo
    echo "== route test =="
    ip route get 1.1.1.1 oif wwan0 2>/dev/null || true

    echo
    echo "== dns =="
    sed -n '1,80p' /etc/resolv.conf || true
    ${pkgs.openresolv}/bin/resolvconf -l 2>/dev/null || true

    echo
    echo "== recent modem log =="
    journalctl -u xmm7360-connect --no-pager -n 40 | grep -E 'IP address|DNS server|Attach failed|ConnectSetup|response:|RegisteredPlmn|ActivateStatus' || true
  '';
  xmm7360UseLte = pkgs.writeShellScriptBin "xmm7360-use-lte" ''
    set -eu

    ip_addr="$(ip -4 -o addr show dev wwan0 scope global | awk '{ split($4, a, "/"); print a[1]; exit }')"
    if [ -z "$ip_addr" ]; then
      echo "wwan0 has no IPv4 address. Start xmm7360-connect first."
      exit 1
    fi

    ip route replace default via "$ip_addr" dev wwan0
    echo "LTE is now the primary default route via $ip_addr."
    echo "DNS is not changed by this helper."
    ip route
  '';
  xmm7360UseDns = pkgs.writeShellScriptBin "xmm7360-use-dns" ''
    set -eu

    ${pkgs.openresolv}/bin/resolvconf -d xmm7360 2>/dev/null || true
    {
      echo "nameserver 213.154.124.1"
      echo "nameserver 193.231.252.1"
    } | ${pkgs.openresolv}/bin/resolvconf -a xmm7360 -x

    echo "Added LTE DNS servers through resolvconf key xmm7360."
    sed -n '1,80p' /etc/resolv.conf
  '';
  xmm7360UseWifi = pkgs.writeShellScriptBin "xmm7360-use-wifi" ''
    set -eu

    ip route del default dev wwan0 2>/dev/null || true
    ip_addr="$(ip -4 -o addr show dev wwan0 scope global | awk '{ split($4, a, "/"); print a[1]; exit }')"
    if [ -n "$ip_addr" ]; then
      ip route del default via "$ip_addr" dev wwan0 2>/dev/null || true
    fi
    ${pkgs.openresolv}/bin/resolvconf -d xmm7360 2>/dev/null || true
    nmcli connection delete xmm7360 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true
    nmcli device connect wlp3s0 2>/dev/null || true

    echo "Removed wwan0 default routes. NetworkManager/Wi-Fi routes are left alone."
    ip route
  '';
  xmm7360Reset = pkgs.writeShellScriptBin "xmm7360-reset" ''
    set -eu

    systemctl stop xmm7360-connect 2>/dev/null || true
    systemctl kill --kill-who=all xmm7360-connect 2>/dev/null || true
    ip route del default dev wwan0 2>/dev/null || true
    ip_addr="$(ip -4 -o addr show dev wwan0 scope global | awk '{ split($4, a, "/"); print a[1]; exit }')"
    if [ -n "$ip_addr" ]; then
      ip route del default via "$ip_addr" dev wwan0 2>/dev/null || true
    fi
    ip link set wwan0 down 2>/dev/null || true
    ${pkgs.openresolv}/bin/resolvconf -d xmm7360 2>/dev/null || true
    nmcli connection delete xmm7360 2>/dev/null || true

    ${pkgs.procps}/bin/pkill -f 'xmm7360-connect|open_xdatachannel.py' 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      modprobe -r xmm7360 2>/dev/null || true
      if ! lsmod | grep -q '^xmm7360 '; then
        break
      fi
      sleep 1
    done

    if lsmod | grep -q '^xmm7360 '; then
      echo "xmm7360 is still loaded. A reboot may be required to clear the modem state."
      exit 1
    fi

    sleep 2
    modprobe xmm7360
    systemctl start xmm7360-connect
    echo "Restarted xmm7360-connect. Wait 45 seconds, then run xmm7360-status."
  '';
in
{
  imports =
    [ 
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      
      # Home Manager
      <home-manager/nixos>
    ];

  home-manager.users.bro = import ../../home/bro/home.nix;

  # Enable graphics driver - unsure if needed
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.enableRedistributableFirmware = true;

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
  boot.extraModulePackages = [ xmm7360Pci ];

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
    layout = "dk";
    variant = "";
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

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Enable Nix command (like search n stuff)
  nix.settings.experimental-features = [
  "nix-command"
  "flakes"
  ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
  
  # System utils
  vim
  wget
  brightnessctl

  # Monitoring vitals
  btop
  htop
  lm_sensors
  nvtopPackages.amd

  # General packages
  librewolf
  libnotify
  fastfetch
  #unstable.sone

  # Mobile broadband
  usbutils
  xmm7360Pci
  xmm7360Reset
  xmm7360Status
  xmm7360UseLte
  xmm7360UseDns
  xmm7360UseWifi
  mobile-broadband-provider-info
  libmbim
  libqmi

  # Games
  superTuxKart

  # Development
  unstable.codex
  gitui

  # Hyprland stuff
  kitty
  waybar
  wofi
  swaynotificationcenter
  wl-clipboard
  grim
  slurp
  hyprpaper
  networkmanagerapplet
  
  ];

  # Fonts

  # Waybar uses these for glyphs
  fonts.packages = with pkgs; [
  font-awesome
  noto-fonts
  noto-fonts-color-emoji
  nerd-fonts.symbols-only
  nerd-fonts.jetbrains-mono
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  programs.hyprland = {
    enable = true;
    withUWSM = true;
    xwayland.enable = true;
  };

  # Services

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
    path = with pkgs; [ gawk kmod openresolv iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
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

  # Keyring
  services.gnome.gnome-keyring.enable = true;

  # greetd
  services.greetd = {
    enable = true;
    settings = {
      default_session = {
        user = "greeter";
        command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --cmd 'uwsm start hyprland-uwsm.desktop'";
      };
    };
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
