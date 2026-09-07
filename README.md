# dotfiles

NixOS setup for my machines. this repo contains helper scripts for adding
packages and adding websites as LibreWolf cookie exceptions.

## where things go

```text
flake.nix              # locked inputs and configurations for all machines
flake.lock             # exact versions of those dependencies
hosts/
  workstation/         # desktop system settings and hardware
  mixi/                 # Apple Silicon Mac mini system settings and hardware
  nixpad/              # laptop system settings and hardware
home/
  nixa/                # workstation apps, dotfiles and package/cookie lists
  bro/                 # laptop apps, dotfiles and package/cookie lists
  mixa/                # mixi shell and Git configuration
scripts/                # shared hostname-aware helper sources
modules/nixos/         # modules used by nixpad
lib/                   # small Nix helpers, like reading package lists
pkgs/                  # local package definitions
```

machine settings go in `hosts/`, personal settings go in `home/`. modules are
Nix files i split out to make settings easier to find or reuse.

each host has its own config. they share a repo without needing to share every
setting.

## flakes

[flake.nix](flake.nix) says what each machine depends on (`inputs`, including
nixpkgs, the package collection) and what it can build (`outputs`, the
workstation and Nixpad NixOS configurations). [flake.lock](flake.lock) records the exact
dependency revisions, so a rebuild uses those versions until i update them.
that's why i keep both files in Git. [more on flakes](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake.html)

for a first look, follow `flake.nix` into
[hosts/workstation/configuration.nix](hosts/workstation/configuration.nix) and
[home/nixa/home.nix](home/nixa/home.nix).

```bash
cd ~/git/dotfiles
sudo nixos-rebuild switch --flake .#workstation
```

`.` means this repo, `#workstation` picks the configuration, and `switch` builds
and applies it. Home Manager is included in that rebuild.

nixpad uses the same root flake, while retaining its own stable package set and
host configuration. Its `/etc/nixos` link points to the host files, not to a
flake root.

mixi uses the pinned `nixos-apple-silicon` input for its Asahi kernel and boot
support. Its device-specific firmware remains in `/boot/vendorfw`: the Asahi
project marks that firmware non-redistributable, so it must not be committed to
this public repository. This is the one local input to an otherwise locked
configuration, and requires `--impure` so Nix may copy it into the store:

```bash
cd ~/git/dotfiles
sudo nixos-rebuild switch --flake .#mixi --impure \
  --option experimental-features "nix-command flakes"
```

the explicit feature option is only needed for the first switch from mixi's
old non-flake configuration. later rebuilds can omit it.

## helpers

these save me opening a config file for small edits. The shared Bash sources
live in [`scripts/`](scripts/); Home Manager installs them as commands on both
machines and picks the matching files from the hostname.

| command | what it does |
| --- | --- |
| `nix-addpkg ripgrep` | checks the name against the locked nixpkgs, then adds it to the user package list |
| `nix-addpkg -s wget` | adds to the system package list instead |
| `nix-addpkg -l` | shows both lists |
| `cookie-allow github.com` | adds a site to LibreWolf's cookie exceptions so it can keep me logged in |

both skip duplicates and stage the edited list in Git. rebuild to apply it,
then commit when you're happy. you can also edit the lists by hand.

<details>
<summary>using the helpers in your own config</summary>

[nix-addpkg.sh](scripts/nix-addpkg.sh) and
[cookie-allow.sh](scripts/cookie-allow.sh) can be copied separately.
you don't need my desktop setup.

- set `NIXOS_CONFIG` to your repo path (the default is `~/git/dotfiles`).
- add a hostname case and matching package/cookie-list paths in the scripts.
- copy the matching `writeShellApplication` block from
[home.nix](home/nixa/home.nix) to install each command with its dependencies.
  or run it with Bash, with those dependencies on your `PATH`.

`nix-addpkg` needs a flake with a `nixpkgs` input, both package-list files, and
[read-packages.nix](lib/read-packages.nix). copy the imports that feed those
lists into `home.packages` and `environment.systemPackages` too. the script
only edits text; those imports turn the text into installed packages.

`cookie-allow` needs the allow-list file and the
`programs.librewolf.policies.Cookies.Allow` setting from my `home.nix`.
that setting reads the list into LibreWolf's policy. the script alone won't
change your browser.

</details>

<details>
<summary>rebuilding and updating</summary>

on the workstation:

```bash
cd ~/git/dotfiles
nixos-rebuild build --flake .#workstation       # build without activating
sudo nixos-rebuild switch --flake .#workstation # build and apply
nh os switch                                  # shorter command on my setup
nix flake update                              # update dependency versions
```

review and commit `flake.lock` after an update and a successful rebuild.
when adding a new config file, `git add` it before building so the flake can
see it. `#nixos` also works as an alias for older commands.

on nixpad, `/etc/nixos` points to
`/home/bro/gitrepos/github/dotfiles/hosts/nixpad`:

```bash
cd /home/bro/gitrepos/github/dotfiles
sudo nixos-rebuild switch --flake .#nixpad
```

</details>

<details>
<summary>screenshots, recording and media</summary>

`Print` takes a region screenshot; `Ctrl+Print` toggles region recording.

- workstation: [screenrecord-toggle](home/nixa/hypr/screenrecord.sh), using
  `slurp` and `wl-screenrec`. files go to `~/Videos/Recordings`; screenshots
  go to `~/Pictures/Screenshots`.
- nixpad: [record-region](home/bro/scripts/screengrab/record-region).
  captures go under `~/Media/Screengrabs/`.
- nixpad: [preview FILE](home/bro/scripts/media/preview) opens images in
  swayimg and videos in mpv.

check each recording script's dependencies and output paths before borrowing it.

wallpapers in `home/bro/wallpapers/` account for most of the repo's size.

</details>

<details>
<summary>nixpad LTE modem</summary>

nixpad's XMM7360 modem uses the local package in `pkgs/xmm7360-pci/` and scripts
in [hosts/nixpad/xmm7360](hosts/nixpad/xmm7360). these are specific to that modem.

```bash
lte-on                     # switch to LTE
lte-off                    # return to Wi-Fi
xmm7360-status             # check modem, routes and DNS
xmm7360-reset              # reset the modem
xmm7360-hard-reset         # PCI/ACPI recovery
```

APN settings live in `/etc/xmm7360`, outside Git; `/etc/xmm7360.example` is the
template. my Digi Mobil Romania APN is `internet`. internet only, no SMS or calls.

</details>
