# dotfiles

Personal NixOS and user configuration.

<details>
<summary>nixpad</summary>

## Host: nixpad

The NixOS system configuration for `nixpad` lives here:

```text
hosts/nixpad/
```

On the machine, `/etc/nixos` is a symlink to:

```text
/home/bro/gitrepos/github/dotfiles/hosts/nixpad
```
**Note**: The git structure defined in the nixOS config is: ~/gitrepos/github and ~/gitrepos/gitea. 


To rebuild:

```bash
sudo nixos-rebuild switch
```

Or to rebuild explicitly from the repo:

```bash
sudo nixos-rebuild switch -I nixos-config=/home/bro/gitrepos/github/dotfiles/hosts/nixpad/configuration.nix
```

## Current structure

```text
hosts/
  nixpad/
    configuration.nix
    hardware-configuration.nix

home/
  bro/
    home.nix
    hypr/
      hyprland.conf
      hyprpaper.conf
    waybar/
      config
```

## Notes

Home Manager user configuration lives in `home/bro/home.nix`.

`hosts/nixpad/configuration.nix` imports that file with:

```nix
home-manager.users.bro = import ../../home/bro/home.nix;
```

Hyprland and Waybar still read their normal live paths under `~/.config`, but
Home Manager creates those files from the tracked repo files:

```text
~/.config/hypr/hyprland.conf  <- home/bro/hypr/hyprland.conf
~/.config/hypr/hyprpaper.conf <- home/bro/hypr/hyprpaper.conf
~/.config/waybar/config       <- home/bro/waybar/config
```

</details>
