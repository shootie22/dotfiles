{ ... }:

{
  imports = [ ./lima-vm.nix ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  system.primaryUser = "radu";
  networking.hostName = "minima";

  nix.enable = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  homebrew = {
    enable = true;

    # Don't remove any existing unmanaged Homebrew packages.
    onActivation.cleanup = "none";

    taps = [
      {
        name = "libkrun/krun";
        trusted = true;
      }
    ];

    brews = [
      "lima"
      "krunkit"
    ];
  };

  programs.zsh = {
    enable = true;
    promptInit = ''
      autoload -U colors && colors
      PROMPT='%F{cyan}%n%f@%F{green}%m%f:%F{blue}%~%f %# '
    '';
  };

  # nix-darwin compatibility version; don't change after initial setup.
  system.stateVersion = 6;
}
