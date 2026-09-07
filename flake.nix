{
  description = "Dotfiles: workstation flake and independent channel-based laptop configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CachyOS BORE+LTO kernel, prebuilt. Its binary cache is added automatically
    # by chaotic.nixosModules.default, so the kernel downloads instead of building.
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Noctalia — Wayland shell / bar.
    noctalia.url = "github:noctalia-dev/noctalia";

    # ai-usagebar — AI plan-quota CLI + TUI (Claude, Codex, ...). Upstream pins
    # a darwin nixpkgs branch; follow ours so it builds against the same tree
    # as everything else.
    ai-usagebar = {
      url = "github:akitaonrails/ai-usagebar";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Noctalia community plugins — used for felipeartur/ai-usagebar, the bar
    # widget + panel that draws `ai-usagebar usage --json`. Plain source tree,
    # not a flake; home.nix links it into the shell's local plugin dir.
    noctalia-plugins = {
      url = "github:noctalia-dev/community-plugins";
      flake = false;
    };

    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { nixpkgs, home-manager, chaotic, noctalia, ... }@inputs: rec {
    nixosConfigurations.workstation = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./hosts/workstation/configuration.nix
        chaotic.nixosModules.default
        noctalia.nixosModules.default

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.users.nixa = import ./home/nixa/home.nix;
        }
      ];
    };
    # Compatibility for older installed helpers and rebuild commands.
    nixosConfigurations.nixos = nixosConfigurations.workstation;
  };
}
