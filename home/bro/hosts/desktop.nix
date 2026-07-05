# Desktop overlay on top of the shared home-manager config.
# The desktop is more powerful and will carry more dev/production tooling
# than the laptop — add those packages here rather than in ../home.nix.
{ config, pkgs, unstable ? pkgs, ... }:

{
  imports = [ ../home.nix ];

  home.packages = with pkgs; [
    # Desktop-only dev/container tooling goes here, e.g.:
    # lazydocker
    # kubectl
  ];
}
