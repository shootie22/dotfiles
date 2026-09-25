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

  # Keep Noctalia's built-in *starship* theme template switched OFF (Settings →
  # Color Scheme → Templates). Its apply.sh does `sed -i` on
  # ~/.config/starship.toml, which home-manager owns as a read-only store
  # symlink: the sed replaces the symlink with a 444 copy carrying
  # `palette = "noctalia"`, then fails to append the matching [palettes.noctalia]
  # block — leaving every new shell printing
  #   [WARN] - (starship::config): Could not find color palette: noctalia
  # The prompt in ../../shared/starship.nix styles itself with plain ANSI names
  # (bold cyan, yellow, …), which Noctalia already recolours through its kitty
  # template, so the starship palette buys nothing. This lives in Noctalia's
  # editable state (~/.local/state/noctalia/settings.toml → theme.templates
  # .builtin_ids); state wins over the config.toml overlay above, so it cannot
  # be pinned from here.
}
