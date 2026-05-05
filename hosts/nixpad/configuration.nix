# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ 
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
      
      # Home Manager
      <home-manager/nixos>
    ];

  home-manager.users.bro = { pkgs, ... }: {
    home.stateVersion = "25.11";

    # Git
    programs.git = {
      enable = true;

      settings = {
        user = {
          name = "Radu N.";
          email = "hello@radunenu.com";
          useConfigOnly = true;
        };

        init.defaultBranch = "main";
      
    
        credential = {
          
          # In memory cache, 1 day
          #helper = "cache --timeout=604800";

          # On disk storage using libsecret
          helper = "${pkgs.git.override { withLibsecret = true; }}/bin/git-credential-libsecret";

          "https://github.com" = {
            username = "shootie22";
          };

          "https://git.radunenu.com" = {
            username = "radu";
          };
        };

      };

      # Gitea config override, folder-based
      #includes = [
      #  {
      #    condition = "gitdir:~/gitrepos/gitea/";
      #    contents = {
      #      user = {
      #        name = "Radu N.";
      #        email = "hello@radunenu.com";
      #      };
      #    };
      #  }
      #];

    };
  };

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

  # Enable SIM card modem
  networking.modemmanager.enable = true;

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
  nvtopPackages.amd

  # General packages
  librewolf
  fastfetch
  element-desktop
  #sone

  # Games
  superTuxKart

  # Development
  codex

  # Hyprland stuff
  kitty
  waybar
  wofi
  mako
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
