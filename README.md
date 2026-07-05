# dotfiles

nixOS and user configuration for my machines

## layout

```text
hosts/
  nixpad/
    configuration.nix          # host config
    hardware-configuration.nix
    xmm7360/                   # LTE helper scripts

home/
  bro/
    home.nix                   # Home Manager config
    hypr/                      # Hyprland + Hyprpaper
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

On `nixpad`, `/etc/nixos` points at:

```text
/home/bro/gitrepos/github/dotfiles/hosts/nixpad
```

## commands

### rebuild

```bash
sudo nixos-rebuild switch
```

explicit config path:

```bash
sudo nixos-rebuild switch -I nixos-config=/home/bro/gitrepos/github/dotfiles/hosts/nixpad/configuration.nix
```

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

`hosts/nixpad/configuration.nix` is the main NixOS file.

it sets the machine basics, imports Home Manager, enables Hyprland/UWSM,
installs system packages, configures fonts, Bluetooth, networking, greetd,
TLP, and the experimental LTE stack.

`<nixos-unstable>` is imported in the host config for selected packages.
Home Manager receives it through `home-manager.extraSpecialArgs`.

</details>

<details>
<summary>home manager</summary>

`home/bro/home.nix` owns user packages, shell-wrapped helper commands, user
services, and tracked config files under `~/.config`.

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

</details>

<details>
<summary>apps</summary>

user-side apps are in Home Manager. currently notable ones:

```text
iamb      matrix client, using unstable package for newer media support
meli      mail client
gitui     terminal git UI, installed system-wide
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
