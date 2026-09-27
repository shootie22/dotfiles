{ ... }:

{
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
      PROMPT='%F{green}[%f%F{cyan}%n%f%F{white}@%f%F{magenta}%m%f%F{green}]%f %F{yellow}·%f %F{blue}%~%f %(!.%F{red}⌘%f.%F{green}⌘%f) '
    '';
  };

  # nix-darwin compatibility version; don't change after initial setup.
  system.stateVersion = 6;
}
