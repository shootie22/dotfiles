{ config, pkgs, unstable ? pkgs, ... }:

let
  dotfilesRoot = "/home/bro/gitrepos/github/dotfiles";
  broHome = "${dotfilesRoot}/home/bro";
  clipboardScripts = "${broHome}/scripts/clipboard";
  wallpaperScripts = "${broHome}/scripts/wallpaper";
  screengrabScripts = "${broHome}/scripts/screengrab";
  mediaScripts = "${broHome}/scripts/media";
in
{
  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    meli
    unstable.iamb
    bitwarden-cli
    cliphist
    file
    mpv
    swayimg
    zellij
    wiremix

    # Games
    runelite

    (writeShellScriptBin "chwp" ''
      exec "${wallpaperScripts}/chwp" "$@"
    '')
    (writeShellScriptBin "change-wallpaper" ''
      exec "${wallpaperScripts}/change-wallpaper" "$@"
    '')
    (writeShellScriptBin "rotate-wallpaper" ''
      exec "${wallpaperScripts}/rotate-wallpaper" "$@"
    '')
    (writeShellScriptBin "screenshot-region" ''
      exec "${screengrabScripts}/screenshot-region" "$@"
    '')
    (writeShellScriptBin "record-region" ''
      exec "${screengrabScripts}/record-region" "$@"
    '')
    (writeShellScriptBin "screencast-status" ''
      exec "${screengrabScripts}/screencast-status" "$@"
    '')
    (writeShellScriptBin "preview" ''
      exec "${mediaScripts}/preview" "$@"
    '')
    (writeShellScriptBin "clipboard-history" ''
      exec "${clipboardScripts}/clipboard-history" "$@"
    '')
    (writeShellScriptBin "cliphist-store" ''
      exec ${pkgs.bash}/bin/bash "${clipboardScripts}/store-clipboard" "$@"
    '')
  ];

  home.pointerCursor = {
    package = pkgs.hackneyed;
    name = "Hackneyed";
    size = 24;

    gtk.enable = true;
    x11.enable = true;
  };

  xdg.configFile = {
    "hypr/hyprland.conf".source = ./hypr/hyprland.conf;
    "hypr/hyprpaper.conf".source =
      config.lib.file.mkOutOfStoreSymlink "${broHome}/hypr/hyprpaper.conf";
    "iamb/config.toml".source = ./iamb/config.toml;
    "kitty/kitty.conf".source = ./kitty/kitty.conf;
    "meli/config.toml" = {
      source = ./meli/config.toml;
      force = true;
    };
    "swaync/config.json".source = ./swaync/config.json;
    "swaync/style.css".source = ./swaync/style.css;
    "ui/panel.css".source = ./theme/panel.css;
    "waybar/config".source = ./waybar/config;
    "waybar/style.css".source = ./waybar/style.css;
    "wofi/clipboard.css".source = ./wofi/clipboard.css;
  };

  systemd.user.services.cliphist-text = {
    Unit = {
      Description = "Store text clipboard history";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.bash}/bin/bash ${clipboardScripts}/store-clipboard";
      Restart = "always";
      RestartSec = 2;
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.cliphist-image = {
    Unit = {
      Description = "Store image clipboard history";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };

    Service = {
      ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.bash}/bin/bash ${clipboardScripts}/store-clipboard";
      Restart = "always";
      RestartSec = 2;
    };

    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.rotate-wallpaper = {
    Unit = {
      Description = "Rotate Hyprland wallpaper";
      After = [ "graphical-session.target" ];
    };

    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${wallpaperScripts}/rotate-wallpaper";
    };
  };

  systemd.user.timers.rotate-wallpaper = {
    Unit.Description = "Rotate Hyprland wallpaper";

    Timer = {
      OnBootSec = "30min";
      OnUnitActiveSec = "30min";
    };

    Install.WantedBy = [ "timers.target" ];
  };

  # Git
  programs.git = {
    enable = true;

    settings = {
      user = {
        name = "Radu N.";
        email = "hello@radunenu.com";
        useConfigOnly = true;
      };

      init.defaultBranch = "main";

      credential = {
        # In memory cache, 1 day
        #helper = "cache --timeout=604800";

        # On disk storage using libsecret
        helper = "${pkgs.git.override { withLibsecret = true; }}/bin/git-credential-libsecret";

        "https://github.com" = {
          username = "shootie22";
        };

        "https://git.radunenu.com" = {
          username = "radu";
        };
      };
    };

    # Gitea config override, folder-based
    #includes = [
    #  {
    #    condition = "gitdir:~/gitrepos/gitea/";
    #    contents = {
    #      user = {
    #        name = "Radu N.";
    #        email = "hello@radunenu.com";
    #      };
    #    };
    #  }
    #];
  };
}
