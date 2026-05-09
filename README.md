# dotfiles

Personal NixOS and user configuration.

## Repository layout

```text
hosts/
  nixpad/             # NixOS host config
    xmm7360/          # host-specific LTE modem helpers

home/
  bro/                # Home Manager user config
    hypr/
    kitty/
    scripts/
      wallpaper/
    swaync/
    wallpapers/
    waybar/

pkgs/
  xmm7360-pci/        # local package override/module build
```

## Host: nixpad

The NixOS system configuration for `nixpad` lives in `hosts/nixpad/`.
On the machine, `/etc/nixos` is a symlink to:

```text
/home/bro/gitrepos/github/dotfiles/hosts/nixpad
```

The git structure defined in the NixOS config is `~/gitrepos/github` and
`~/gitrepos/gitea`.

To rebuild:

```bash
sudo nixos-rebuild switch
```

Or to rebuild explicitly from the repo:

```bash
sudo nixos-rebuild switch -I nixos-config=/home/bro/gitrepos/github/dotfiles/hosts/nixpad/configuration.nix
```

## Home Manager

Home Manager user configuration lives in `home/bro/home.nix`.
`hosts/nixpad/configuration.nix` imports that file with:

```nix
home-manager.users.bro = import ../../home/bro/home.nix;
```

Hyprland, Kitty, SwayNC, and Waybar read their normal live paths under
`~/.config`, and Home Manager creates those files from tracked repo files.

Most configs are normal Home Manager store links. `hyprpaper.conf` is an
out-of-store symlink so the wallpaper helper can update the repo config directly.

## Wallpaper Scripts

Wallpaper startup config is managed by Home Manager as an out-of-store symlink so
the helper can update the repo directly. The `chwp` command is installed through
Home Manager as a small wrapper around the standalone repo script. To copy a
wallpaper into the repo, persist it, and reload Hyprpaper, use:

```sh
chwp ~/Media/Wallpapers/foo.jpg
```

Use `chwp --move-file ~/Downloads/foo.jpg` to move the source file into the repo
instead of copying it.

Use `chwp --which` to print the wallpaper currently configured.

The implementation lives at `home/bro/scripts/wallpaper/change-wallpaper`; `chwp`
is only a short alias. It can be reused outside this repo by setting
`CHWP_WALLPAPER_DIR` and `CHWP_HYPRPAPER_CONFIG`.

## Screengrab Scripts

Region screenshots and recordings are handled by small scripts in
`home/bro/scripts/screengrab/`.

```text
Print        freeze screen, select a region, save a screenshot
Ctrl+Print   select a region and start recording; press again to stop
```

Files are saved under:

```text
~/Media/Screengrabs/Screenshots/
~/Media/Screengrabs/Recordings/
```

Save notifications use the screenshot image directly. Recording notifications
use a generated thumbnail from the saved video. Recording thumbnails are stored
under `~/.cache/screengrab-thumbnails/` and old thumbnails are pruned.

## Media Preview

`preview FILE` opens image files with `swayimg` and video files with `mpv`.

## Experimental LTE modem

<details>
<summary>What hardware this is</summary>

`nixpad` has an internal Fibocom L850-GL / Intel XMM7360 LTE modem.

The kernel can see the card, but ModemManager rejects it in RPC mode:

```text
Intel XMM7360 in RPC mode not supported
```

Because of that, this setup uses the experimental `xmm7360-pci` driver and
RPC helper instead of ModemManager.

</details>

<details>
<summary>What the NixOS config does</summary>

The host config:

- disables ModemManager for this machine, because it cannot manage this modem
- blacklists the in-kernel `iosm` driver, because the experimental driver must bind instead
- builds a local `xmm7360-pci` kernel module from `pkgs/xmm7360-pci`
- installs helper commands for reset, hard reset, status, LTE routing/DNS, and Wi-Fi routing
- installs `xmm7360-connect.service`, which attaches the modem but does not change default routes
- removes `element-desktop`, because the current package pulled insecure `olm`
  and blocked NixOS rebuilds

The local package also patches upstream for the current kernel:

- points the module build at the active NixOS kernel headers
- adjusts the TTY write callback signature for Linux 6.8+
- makes the RPC helper exit successfully after data-channel setup
- makes failed data-channel RPC setup fail the service instead of pretending the
  modem is connected
- lowers helper logging from DEBUG to INFO

</details>

<details>
<summary>Configuration file</summary>

Create `/etc/xmm7360` from the generated example:

```bash
sudo cp /etc/xmm7360.example /etc/xmm7360
sudoedit /etc/xmm7360
```

For Digi Mobil Romania, the APN is:

```ini
apn=internet
```

The example also includes `metric=1000`, but the current helper flow does not
use automatic LTE metrics. Route switching is explicit.

</details>

<details>
<summary>Helper commands</summary>

`xmm7360-reset`

Stops the service, removes stale LTE routes, deletes any stale NetworkManager
`xmm7360` connection left from earlier experiments, removes the LTE DNS entry,
kills leftover connector processes, reloads the `xmm7360` kernel module, and
starts `xmm7360-connect.service`. It waits for `wwan0` to receive an IPv4
address, but does not make LTE the default route.

`xmm7360-hard-reset`

Opt-in recovery command for stuck modem state. It performs the normal cleanup,
unloads the module, calls the machine-specific ACPI reset method
`\_SB.PCI0.GPP7.L850._RST`, waits for the `xmm7360` driver to bind, and falls
back to PCI remove/rescan if needed. After reset it gives the modem firmware a
boot delay before probing the driver, then a short settle delay after binding,
waits for the RPC device node, starts the service, and waits for `wwan0` to
receive an IPv4 address. Use it when `xmm7360-reset` cannot recover the modem
without a reboot.

`xmm7360-hard-reset` depends on the out-of-tree `acpi_call` kernel module. After
first adding that module to the NixOS config, reboot once so it is available in
`/run/booted-system`.

`xmm7360-status`

Prints the service state, active PCI driver, `wwan0` address, packet counters,
routes, DNS state, and recent modem log lines.

`xmm7360-use-lte`

Adds the direct default route through the current `wwan0` IPv4 address, enables
the LTE DNS resolver entry, and verifies packet flow with a bound ping. If the
packet test fails, it removes the LTE route and DNS entry again so Wi-Fi routing
is not left broken.

`xmm7360-use-dns`

Adds the Digi Mobil DNS servers through openresolv using an exclusive
`xmm7360` resolver entry. This lets `/etc/resolv.conf` be regenerated by the
system instead of editing it directly.

`xmm7360-use-wifi`

Removes LTE default routes, deletes the `xmm7360` openresolv DNS entry, and
asks NetworkManager to reconnect Wi-Fi.

</details>

<details>
<summary>LTE workflow</summary>

Current reliable LTE-on path:

```bash
sudo xmm7360-hard-reset
xmm7360-status
sudo xmm7360-use-lte
ping -I wwan0 -c 4 1.1.1.1
ping -I wwan0 -c 4 example.com
```

Lighter reconnect path, useful for debugging but less reliable after toggling:

```bash
sudo xmm7360-reset
sudo xmm7360-use-lte
```

Return to Wi-Fi:

```bash
sudo xmm7360-use-wifi
ping -I wlp3s0 -c 4 1.1.1.1
```

The wait is needed because `wwan0` can receive an IP before the modem has
finished attaching and setting up the packet data channel. The useful log signs
are:

```text
INFO:root:IP address: ...
INFO:root:DNS server(s): ...
RPC executing UtaRPCPSConnectSetupReq
response: 0x0
```

</details>

<details>
<summary>Limitations</summary>

This is experimental support, not normal ModemManager integration.

- Internet can work after the manual reset/connect/route flow.
- DNS is configured by `xmm7360-use-lte` or `xmm7360-use-dns`, and the LTE DNS
  entry is removed by `xmm7360-use-wifi` or `xmm7360-reset`.
- SMS and calls are not supported through this setup.
- Restarts can leave the modem in a bad state; use `xmm7360-reset`,
  `xmm7360-hard-reset`, or reboot.
- A supported MBIM/QMI USB modem or hotspot would be more reliable for daily use.

</details>
