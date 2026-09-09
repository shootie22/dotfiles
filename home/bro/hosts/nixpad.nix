# Laptop overlay on top of the shared home-manager config.
# Keep this minimal — nixpad is the intentionally-lean install.
{ config, pkgs, unstable ? pkgs, ... }:

{
  imports = [ ../home.nix ];

  # Noctalia v5 reads its editable state from ~/.local/state, but also merges
  # this declarative config overlay.  Its supported bar-level wheel handler
  # applies to the unoccupied (dead-zone) portion of the bar.
  xdg.configFile."noctalia/config.toml".text = ''
    [bar.default.dead_zone]
    scroll_up_command = "hyprctl dispatch workspace e-1"
    scroll_down_command = "hyprctl dispatch workspace e+1"
  '';
}
