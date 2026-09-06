# dotfiles

nixOS and user configuration for my machines

## layout

```text
hosts/
  nixpad/
    configuration.nix          # laptop-only bits: LTE, TLP, LUKS, locale
    hardware-configuration.nix
    xmm7360/                   # LTE helper scripts
  desktop/
    configuration.nix          # desktop-only bits: docker, no LTE
    hardware-configuration.nix # placeholder until generated on the machine

modules/
  nixos/
    common.nix                 # shared base packages, fonts, nix settings
    desktop-hyprland.nix       # Hyprland/UWSM, greetd, graphics, keyring
    gaming.nix                 # Steam/gamemode, behind modules.gaming.enable

home/
  bro/
    home.nix                   # shared Home Manager config
    hosts/
      nixpad.nix                # thin per-host overlay -> imports ../home.nix
      desktop.nix                # thin per-host overlay -> imports ../home.nix
    hypr/                       # Hyprland; hyprland.conf sources the *.conf below
      look.conf                  # general/decoration/animations
      input.conf                  # keyboard/touchpad/gestures
      keybinds.conf                # all binds — the file to edit for a new shortcut
      windowrules.conf
    iamb/
    kitty/
    meli/
    scripts/
      media/
      screengrab/
    wallpapers/

pkgs/
  xmm7360-pci/                 # local kernel module package
```

Both hosts import the same `modules/nixos/*` files and set only what differs
(host packages, `modules.gaming.enable`, LTE, locale). Adding a third
machine means a new `hosts/<name>/` + `home/bro/hosts/<name>.nix` that import
the existing modules and `home.nix`, picking which shared pieces to enable.

On `nixpad`, `/etc/nixos` points at:

```text
/home/bro/gitrepos/github/dotfiles/hosts/nixpad
```

## commands

### rebuild

This is a flake. Every input (nixpkgs, nixpkgs-unstable, home-manager,
noctalia) is pinned in `flake.lock`, so a rebuild produces the same system
regardless of channel state.

```bash
cd /home/bro/gitrepos/github/dotfiles
sudo nixos-rebuild switch --flake .#nixpad
sudo nixos-rebuild switch --flake .#desktop
```

Note `/etc/nixos` symlinks to `hosts/nixpad`, but `flake.nix` lives at the
repo *root*, so `--flake /etc/nixos#nixpad` does not work. Either run from
the repo root as above, or give the absolute path:

```bash
sudo nixos-rebuild switch --flake /home/bro/gitrepos/github/dotfiles#nixpad
```

**New files must be `git add`ed first.** Flakes only see git-tracked files,
so an untracked module is invisible to the build and fails with a confusing
"file not found". Modified tracked files are picked up without committing.

Updating inputs is deliberate, and lands as a reviewable diff:

```bash
nix flake update              # all inputs
nix flake update nixpkgs      # just one
```

Channels are no longer used for the system build. A `nix-channel --update`
will not change what this repo builds -- which is the point: an unnoticed
channel bump to Hyprland 0.55 is what broke the Hyprland config previously.

### media

```bash
preview FILE               # images in swayimg, videos in mpv
kitten icat IMAGE          # show an image in kitty
```

### screengrabs

```bash
record-region              # select/start/stop recording
```

```text
Print                      region screenshot with Noctalia
Ctrl+Print                 start/stop region recording
```

files go under:

```text
~/Media/Screengrabs/Screenshots/
~/Media/Screengrabs/Recordings/
```

### clipboard

```text
Super                      launcher
Super+V                    Noctalia clipboard history
Super+Z                    toggle floating
```

### LTE

```bash
lte-on                     # switch internet to LTE
lte-on --verbose
lte-off                    # return to Wi-Fi
lte-off --verbose
xmm7360-status             # modem/service/routes/DNS status
xmm7360-reset              # normal modem reset
xmm7360-hard-reset         # ACPI/PCI recovery path
xmm7360-use-lte            # lower-level LTE routing/DNS
xmm7360-use-wifi           # lower-level Wi-Fi restore
xmm7360-use-dns            # install LTE DNS only
```

## config notes

<details>
<summary>host</summary>

each `hosts/<name>/configuration.nix` sets machine basics (hostname, locale,
bootloader, users) and imports the shared modules under `modules/nixos/`:
`common.nix` (base packages/fonts), `desktop-hyprland.nix` (Hyprland/UWSM,
greetd, graphics, keyring — both hosts use this), and `gaming.nix` (Steam,
opt-in per host via `modules.gaming.enable = true;`).

`nixpad` additionally owns the LTE modem stack, TLP, and LUKS — all
laptop-specific, so they stay in `hosts/nixpad/configuration.nix` rather than
a shared module. `desktop` additionally enables `virtualisation.docker` for
container/dev work.

`unstable` (nixpkgs-unstable) and the pinned Noctalia package are built in
`flake.nix` and handed to every NixOS module via `specialArgs`, so
`modules/nixos/*.nix` and the host configs take `unstable`/`noctalia` as
ordinary module arguments. Home Manager gets `unstable` via
`home-manager.extraSpecialArgs`.

setting up a new host: add a `nixosConfigurations.<name> = mkHost "<name>";`
entry in `flake.nix`, run `sudo nixos-generate-config --dir hosts/<name>` on
the machine for a real `hardware-configuration.nix`, and pick which
`modules/nixos/*` to import.

</details>

<details>
<summary>home manager</summary>

`home/bro/home.nix` owns user packages, shell-wrapped helper commands, user
services, and tracked config files under `~/.config` — shared by every host.

`home/bro/hosts/<name>.nix` is a thin per-host overlay that imports
`../home.nix` and adds only what that machine needs (see `desktop.nix` for
where dev/container tooling goes). Each NixOS host's
`home-manager.users.bro` points at its own overlay file.

</details>

<details>
<summary>desktop</summary>

tracked desktop config:

```text
home/bro/hypr/
home/bro/kitty/
```

current desktop pieces include Hyprland, Noctalia, Kitty, Hackneyed cursors,
recording, and media previews.

`home/bro/hypr/hyprland.conf` only sets monitors/programs/autostart/env, then
`source`s `look.conf`, `input.conf`, `keybinds.conf`, and `windowrules.conf`.
Each of those is symlinked individually via `xdg.configFile` in `home.nix`
(matching the pattern used for `iamb`/`kitty`/`meli`). To change a shortcut,
edit `keybinds.conf` — no other file needs touching. Adding a brand-new
partial still needs one line added to `home.nix`'s `xdg.configFile`.

</details>

<details>
<summary>apps</summary>

user-side apps are in Home Manager. currently notable ones:

```text
iamb      matrix client, using unstable package for newer media support
meli      mail client
gitui     terminal git UI, installed system-wide
localsend LAN file transfer, system-wide via `programs.localsend` (opens 53317)
wiremix   audio mixer
runelite
```

`iamb` config enables kitty image previews.

</details>

<details>
<summary>wallpapers</summary>

the wallpaper library lives in:

```text
home/bro/wallpapers/
```

Noctalia owns wallpaper selection and rotation.

</details>

<details>
<summary>LTE modem</summary>

`nixpad` has a Fibocom L850-GL / Intel XMM7360 modem.

ModemManager does not manage this card in RPC mode:

```text
Intel XMM7360 in RPC mode not supported
```

so this repo uses:

```text
pkgs/xmm7360-pci/
hosts/nixpad/xmm7360/
```

the host config disables ModemManager for this machine, blacklists `iosm`,
builds the local `xmm7360` module, enables `acpi_call`, and installs the LTE
wrapper commands.

APN config lives outside git:

```bash
sudo cp /etc/xmm7360.example /etc/xmm7360
sudoedit /etc/xmm7360
```

for Digi Mobil Romania:

```ini
apn=internet
```

this is internet-only experimental support. SMS and calls are not handled here.

</details>
