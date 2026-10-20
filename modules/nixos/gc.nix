# `sudo gc`: every old generation gone (the user's who ran sudo, root's and
# the system's), the store collected, and the boot menu down to what's left.
# `sudo gc 7d` keeps the last 7 days instead.
{ pkgs, ... }:

let
  gc = pkgs.writeShellScriptBin "gc" ''
    set -eu
    if [ "$(id -u)" -ne 0 ]; then
      echo "run it as sudo gc" >&2
      exit 1
    fi
    case "''${1:-}" in
      "") gens=old; opt=-d ;;
      *[0-9]d) gens=$1; opt="--delete-older-than $1" ;;
      *) echo "usage: sudo gc [7d]" >&2; exit 1 ;;
    esac
    before=$(df --output=avail -B1 /nix/store | tail -1)
    # The user's profiles (home-manager, nix profile) are in their home, out
    # of root's reach.
    if [ -n "''${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
      echo "== $SUDO_USER's generations"
      for p in /home/"$SUDO_USER"/.local/state/nix/profiles/*; do
        case "$p" in *-link) continue ;; esac
        [ -e "$p" ] && ${pkgs.util-linux}/bin/runuser -u "$SUDO_USER" -- nix-env -p "$p" --delete-generations "$gens" 2>/dev/null || true
      done
    fi
    echo "== system and root generations, then the store"
    # shellcheck disable=SC2086
    nix-collect-garbage $opt
    echo "== boot menu"
    /run/current-system/bin/switch-to-configuration boot
    after=$(df --output=avail -B1 /nix/store | tail -1)
    echo "freed $(numfmt --to=iec $((after - before)))"
  '';
in
{
  environment.systemPackages = [ gc ];
}
