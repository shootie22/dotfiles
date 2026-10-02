# Keeps the dotfiles checkout on a desktop in step with GitHub, without ever
# touching local work (infrastructure repo, docs/ha/decisions.md, "Every
# machine follows Git"). Every minute: fetch; fast-forward only when the tree
# is clean and nothing is unpushed; otherwise leave it alone and say so once
# with a desktop notification. Never rebuilds anything.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.sync;
  script = pkgs.writeShellScript "dotfiles-sync" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.coreutils pkgs.libnotify pkgs.openssh ]}
    repo=${lib.escapeShellArg cfg.path}
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles-sync"
    mkdir -p "$(dirname "$state")"
    cd "$repo" 2>/dev/null || exit 0

    git fetch --quiet origin 2>/dev/null || exit 0  # offline: try again next minute
    behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
    [ "$behind" -eq 0 ] && { : > "$state"; exit 0; }

    dirty=$(git status --porcelain --untracked-files=no)
    ahead=$(git rev-list --count @{u}..HEAD)
    if [ -z "$dirty" ] && [ "$ahead" -eq 0 ]; then
      git merge --ff-only --quiet @{u} && : > "$state"
      exit 0
    fi

    # Behind, but there's local work: don't touch it, tell once per situation.
    msg="dotfiles: $behind behind origin"
    [ -n "$dirty" ] && msg="$msg, local changes"
    [ "$ahead" -gt 0 ] && msg="$msg, $ahead unpushed"
    if [ "$(cat "$state" 2>/dev/null)" != "$msg" ]; then
      notify-send --app-name=dotfiles "Dotfiles not synced" "$msg" 2>/dev/null || true
      echo "$msg" > "$state"
    fi
    echo "$msg"
  '';
in
{
  options.dotfiles.sync = {
    enable = lib.mkEnableOption "keeping the dotfiles checkout synced";
    user = lib.mkOption { type = lib.types.str; };
    path = lib.mkOption { type = lib.types.str; };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.dotfiles-sync = {
      description = "Keep the dotfiles checkout in step with GitHub";
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = script;
      };
    };
    systemd.user.timers.dotfiles-sync = {
      wantedBy = [ "timers.target" ];
      unitConfig.ConditionUser = cfg.user;
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "1min";
      };
    };
  };
}
