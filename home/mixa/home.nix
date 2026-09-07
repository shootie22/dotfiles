# Home Manager configuration for the headless mixi host.
{ ... }:

{
  imports = [ ../shared/starship.nix ];

  home = {
    username = "mixa";
    homeDirectory = "/home/mixa";
    stateVersion = "26.11";

    # Preserve the path added by the previous hand-written ~/.bashrc.
    sessionPath = [ "$HOME/.local/bin" ];

    sessionVariables = {
      NIXOS_CONFIG = "$HOME/git/dotfiles";
      NH_FLAKE = "$HOME/git/dotfiles#mixi";
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
