# Builds the desktops' systems (this one and nixpad) from GitHub's main in the
# background, so a rebuild after an update (the weekly flake.lock PR) finds
# everything already built. fuji doesn't build the desktops any more: their
# rustc, Electron apps and CachyOS kernel took it hours (infrastructure
# repo, docs/updates.md). Never switches anything.
#
# Checks every hour while the machine is on and builds only a commit it
# hasn't built yet. The results stay as GC roots in /var/lib/desktop-prebuild
# until the next build replaces them. Builds run in the nix-daemon at idle
# CPU and IO priority, so a game or a manual rebuild always comes first.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.desktopPrebuild;
  repo = "github:shootie22/dotfiles";
in
{
  options.dotfiles.desktopPrebuild = {
    enable = lib.mkEnableOption "building the desktops' systems from main in the background";
    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "workstation" "nixpad" ];
    };
  };

  config = lib.mkIf cfg.enable {
    nix.daemonCPUSchedPolicy = "idle";
    nix.daemonIOSchedClass = "idle";

    systemd.services.desktop-prebuild = {
      description = "Build the desktops' systems from dotfiles main";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ nix git coreutils ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "desktop-prebuild";
        Nice = 19;
        TimeoutStartSec = "12h";
      };
      script = ''
        set -eu
        state=/var/lib/desktop-prebuild
        rev=$(git ls-remote https://github.com/shootie22/dotfiles.git refs/heads/main | cut -f1)
        [ -n "$rev" ] || { echo "couldn't reach GitHub"; exit 0; }
        if [ "$(cat "$state/built" 2>/dev/null)" = "$rev" ]; then
          echo "$rev already built"
          exit 0
        fi
        # A commit that doesn't build is tried once, not every hour.
        if [ "$(cat "$state/failed" 2>/dev/null)" = "$rev" ]; then
          echo "$rev failed before, waiting for a new commit"
          exit 0
        fi
        for h in ${lib.escapeShellArgs cfg.hosts}; do
          echo "building $h at $rev"
          nix build --out-link "$state/$h" "${repo}/$rev#nixosConfigurations.$h.config.system.build.toplevel" \
            || { echo "$rev" > "$state/failed"; exit 1; }
        done
        echo "$rev" > "$state/built"
      '';
    };

    systemd.timers.desktop-prebuild = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "1h";
      };
    };
  };
}
