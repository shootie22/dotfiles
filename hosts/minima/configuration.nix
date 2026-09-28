{ ... }:

{
  imports = [
    ./lima-vm.nix
    ./vm-backup.nix
  ];

  nixpkgs.hostPlatform = "aarch64-darwin";

  system.primaryUser = "radu";

  # Admin devices log in with keys (served to sshd from /etc/ssh); Borg's
  # purpose-limited keys for borgworker stay in that user's own file.
  users.users.radu.openssh.authorizedKeys.keys =
    builtins.attrValues (import ../../lib/admin-ssh-keys.nix);
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
