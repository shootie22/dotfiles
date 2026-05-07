{ pkgs, ... }:

{
  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    meli
  ];

  xdg.configFile = {
    "hypr/hyprland.conf".source = ./hypr/hyprland.conf;
    "hypr/hyprpaper.conf".source = ./hypr/hyprpaper.conf;
    "kitty/kitty.conf".source = ./kitty/kitty.conf;
    "swaync/config.json".source = ./swaync/config.json;
    "swaync/style.css".source = ./swaync/style.css;
    "waybar/config".source = ./waybar/config;
    "waybar/style.css".source = ./waybar/style.css;
  };

  xdg.dataFile."wallpapers".source = ./wallpapers;

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
