# Laptop overlay on top of the shared home-manager config.
# Keep this minimal — nixpad is the intentionally-lean install.
{ config, pkgs, unstable ? pkgs, ... }:

{
  imports = [ ../home.nix ];

  # Laptop-only home-manager additions go here.
}
