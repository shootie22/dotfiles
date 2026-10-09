# Sunshine game/desktop streaming host, for Moonlight on the laptop over the
# tailnet. Reachable on tailscale0 only. A paired client gets in with its
# certificate, so there's no per-session code; pairing itself is a PIN typed
# into the web UI at https://<host>:47990 (tailnet only, login set on first
# visit).
#
# Each stream gets a headless Hyprland output sized to the client, with the
# physical monitors switched off for its duration. The session locks when a
# stream starts and again when it ends, so pairing alone only reaches the
# lock screen.
#
# Enable per-host with:
#   dotfiles.gameStreaming.enable = true;
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.gameStreaming;
  output = "SUNSHINE";
  state = "$XDG_RUNTIME_DIR/sunshine-monitors";

  # Sunshine runs as a user service under UWSM, so the Hyprland instance and
  # the session PATH (noctalia) come from the user manager's environment.
  env = ''
    set -u
    export PATH=${lib.makeBinPath [ config.programs.hyprland.package pkgs.jq pkgs.coreutils ]}:/run/current-system/sw/bin:/etc/profiles/per-user/${cfg.user}/bin
  '';

  streamStart = pkgs.writeShellScript "sunshine-stream-start" ''
    ${env}
    # Remember the physical monitors with their modes, to restore them after.
    hyprctl monitors -j | jq -r '.[] | select(.name != "${output}")
      | "\(.name) \(.width)x\(.height)@\(.refreshRate | round)"' > "${state}"

    hyprctl output create headless ${output}
    hyprctl eval "hl.monitor({ output = \"${output}\", mode = \"''${SUNSHINE_CLIENT_WIDTH}x''${SUNSHINE_CLIENT_HEIGHT}@''${SUNSHINE_CLIENT_FPS}\", position = \"auto\", scale = 1 })"
    # Disabling a monitor moves its workspaces to what's left: the headless one.
    while read -r name _; do
      hyprctl eval "hl.monitor({ output = \"$name\", disabled = true })"
    done < "${state}"

    noctalia msg session lock
  '';

  streamEnd = pkgs.writeShellScript "sunshine-stream-end" ''
    ${env}
    while read -r name mode; do
      hyprctl eval "hl.monitor({ output = \"$name\", mode = \"$mode\", position = \"auto\", scale = 1 })"
    done < "${state}"
    hyprctl output remove ${output}
    rm -f "${state}"

    noctalia msg session lock
  '';
in
{
  options.dotfiles.gameStreaming = {
    enable = lib.mkEnableOption "Sunshine streaming to Moonlight over the tailnet";
    user = lib.mkOption {
      type = lib.types.str;
      default = "nixa";
      description = "The user whose Hyprland session is streamed.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.sunshine = {
      enable = true;
      autoStart = true;
      # wlr capture (Hyprland screencopy) can see the headless output; KMS
      # capture can't, and it would need CAP_SYS_ADMIN.
      capSysAdmin = false;
      openFirewall = false;   # tailnet only, below
      settings = {
        sunshine_name = config.networking.hostName;
        capture = "wlr";
        encoder = "vaapi";
        origin_web_ui_allowed = "lan";   # private + tailnet (100.64/10) addresses; the firewall limits it to tailscale0
        # The web UI is opened by tailnet name, which Sunshine doesn't know is its own.
        csrf_allowed_origins = "https://${config.networking.hostName}.tail.radunenu.com:47990";
        global_prep_cmd = builtins.toJSON [ { do = "${streamStart}"; undo = "${streamEnd}"; } ];
      };
      applications.apps = [
        { name = "Desktop"; image-path = "desktop.png"; }
        {
          name = "Steam Big Picture";
          image-path = "steam.png";
          detached = [ "setsid steam steam://open/bigpicture" ];
          prep-cmd = [ { do = ""; undo = "setsid steam steam://close/bigpicture"; } ];
        }
      ];
    };

    # Nothing to advertise on the LAN; Moonlight finds it by tailnet name.
    # Beats the sunshine module's mkDefault, yields to any host that wants avahi.
    services.avahi.enable = lib.mkOverride 900 false;

    # Base port 47989, see services.sunshine's generatePorts.
    networking.firewall.interfaces.tailscale0 = {
      allowedTCPPorts = [ 47984 47989 47990 48010 ];
      allowedUDPPorts = [ 47998 47999 48000 48002 48010 ];
    };
  };
}
