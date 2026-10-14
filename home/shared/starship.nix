# Shared Bash prompt used by mixi, nixpad and fuji. This mirrors the
# workstation's prompt while keeping that host's existing configuration
# untouched. The settings are in starship-settings.nix, which the Mac's zsh
# uses too.
{ lib, ... }:

{
  programs.bash.enable = true;

  programs.starship = {
    enable = true;
    settings = import ./starship-settings.nix { inherit lib; };
  };
}
