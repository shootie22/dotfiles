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
    hypr/
      hyprland.conf
      hyprpaper.conf
```

## Notes

Home Manager currently manages Git configuration.

</details>
