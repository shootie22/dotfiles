{ lib, pkgs, ... }:

{
  imports = [
    ./lima-vm.nix
    ./vm-backup.nix
    ./gitea-runner.nix
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

  # The same Starship prompt as the Linux machines (home/shared), for zsh.
  environment.systemPackages = [ pkgs.starship ];
  environment.variables.STARSHIP_CONFIG = toString
    ((pkgs.formats.toml { }).generate "starship.toml"
      (import ../../home/shared/starship-settings.nix { inherit lib; }));

  programs.zsh = {
    enable = true;
    promptInit = ''eval "$(${lib.getExe pkgs.starship} init zsh)"'';
  };

  # nix-darwin compatibility version; don't change after initial setup.
  system.stateVersion = 6;
}
