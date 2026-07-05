# Placeholder — this machine's real hardware-configuration.nix has not been
# generated yet. Do NOT hand-write fileSystems/swapDevices/UUIDs here.
#
# On the desktop machine, run:
#   sudo nixos-generate-config --dir /home/bro/gitrepos/github/dotfiles/hosts/desktop
# then commit the resulting hardware-configuration.nix over this file (and
# fold any boot.loader bits it suggests into configuration.nix).
{ config, lib, pkgs, modulesPath, ... }:

throw ''
  hosts/desktop/hardware-configuration.nix is a placeholder.
  Run `sudo nixos-generate-config --dir <this repo>/hosts/desktop` on the
  actual desktop machine and commit the real file over this one.
''
