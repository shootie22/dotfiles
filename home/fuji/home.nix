# Home Manager configuration for the headless fuji server.
{ ... }:

{
  imports = [ ../shared/starship.nix ];

  home = {
    username = "fuji";
    homeDirectory = "/home/fuji";
    stateVersion = "26.05";

    sessionVariables = {
      NIXOS_CONFIG = "$HOME/git/dotfiles";
      NH_FLAKE = "$HOME/git/dotfiles#fuji";
    };
  };

  programs = {
    home-manager.enable = true;
    bash.enable = true;

    git = {
      enable = true;
      settings = {
        user = {
          name = "Radu N.";
          email = "hello@radunenu.com";
          useConfigOnly = true;
        };
        init.defaultBranch = "main";
        credential."https://github.com".username = "shootie22";
      };
    };
  };
}
