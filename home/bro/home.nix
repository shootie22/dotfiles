{ config, pkgs, unstable ? pkgs, ... }:

let
  dotfilesRoot = "/home/bro/gitrepos/github/dotfiles";
  broHome = "${dotfilesRoot}/home/bro";
  screengrabScripts = "${broHome}/scripts/screengrab";
  mediaScripts = "${broHome}/scripts/media";
in
{
  home.stateVersion = "25.11";

  nixpkgs.config.allowUnfree = true;

  home.packages = with pkgs; [

    # general
    meli
    unstable.iamb
    bitwarden-cli
    file
    mpv
    swayimg
    zellij
    wiremix
    parsec-bin
    xfce.thunar

    # utilities
    calcurse
    tealdeer
    helix
    unstable.claude-code

    # Games
    runelite

    (writeShellScriptBin "record-region" ''
      exec "${screengrabScripts}/record-region" "$@"
    '')
    (writeShellScriptBin "preview" ''
      exec "${mediaScripts}/preview" "$@"
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
    "hypr/look.conf".source = ./hypr/look.conf;
    "hypr/input.conf".source = ./hypr/input.conf;
    "hypr/keybinds.conf".source = ./hypr/keybinds.conf;
    "hypr/windowrules.conf".source = ./hypr/windowrules.conf;
    "iamb/config.toml".source = ./iamb/config.toml;
    "kitty/kitty.conf".source = ./kitty/kitty.conf;
    "meli/config.toml" = {
      source = ./meli/config.toml;
      force = true;
    };
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
