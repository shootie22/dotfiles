# dotfiles

my NixOS setup for two machines: `workstation` (desktop, user `nixa`) and
`nixpad` (laptop, user `bro`). both run Hyprland and Noctalia.

NixOS keeps my packages, services and system settings in files. Home Manager
handles my apps and dotfiles. i edit, rebuild, and keep the changes in Git.

if you're borrowing from this repo, start with the bits you like. the disk
layout, hardware config and usernames belong to my machines.

## where things go

```text
flake.nix              # workstation entry point: dependencies + config to build
flake.lock             # exact versions of those dependencies
hosts/
  workstation/         # desktop system settings and hardware
  nixpad/              # laptop system settings and hardware
  desktop/             # unfinished bro desktop config, not the workstation
home/
  nixa/                # workstation apps, dotfiles and helpers
  bro/                 # laptop apps, dotfiles and helpers
modules/nixos/         # modules used by nixpad and the unfinished desktop
lib/                   # small Nix helpers, like reading package lists
pkgs/                  # local package definitions
```

machine settings go in `hosts/`, personal settings go in `home/`. modules are
Nix files i split out to make settings easier to find or reuse.

the workstation has its own config; it doesn't import the laptop's modules.
they share a repo without needing to share every setting.

## why flakes

[flake.nix](flake.nix) says what the workstation depends on (`inputs`, including
nixpkgs, the package collection) and what it can build (`outputs`, here the
workstation's NixOS configuration). [flake.lock](flake.lock) records the exact
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

nixpad still builds through channels, using its own config under `/etc/nixos`.
it doesn't use this root flake. i left its working setup alone.

## little helpers

these save me opening a config file for small edits. they're plain Bash scripts;
Home Manager installs them as commands.

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

[nix-addpkg.sh](home/nixa/scripts/nix-addpkg.sh) and
[cookie-allow.sh](home/nixa/scripts/cookie-allow.sh) can be copied separately.
you don't need my desktop setup.

- set `NIXOS_CONFIG` to your repo path (the default is `~/git/dotfiles`).
- change the `home/nixa` and `hosts/workstation` paths inside the scripts to
  match your layout, plus `#workstation` in the printed rebuild command.
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
sudo nixos-rebuild switch
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
