{
  description = "Reproducible NixOS configurations for mixi, nixpad, and workstation";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Nixpad deliberately remains on stable, with a small set of packages
    # sourced from unstable. Keeping this separate preserves its tested build
    # rather than changing it when the workstation's rolling input updates.
    nixpkgs-nixpad.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-nixpad-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Kernel, bootloader, and peripheral support for the Apple Silicon Mac mini.
    # Following the main nixpkgs input keeps the kernel module and userspace in
    # sync while flake.lock pins the exact support revision.
    apple-silicon = {
      url = "github:nix-community/nixos-apple-silicon";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-nixpad = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-nixpad";
    };

    # CachyOS BORE+LTO kernel, prebuilt. Its binary cache is added automatically
    # by chaotic.nixosModules.default, so the kernel downloads instead of building.
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Noctalia — Wayland shell / bar.
    noctalia.url = "github:noctalia-dev/noctalia";

    # Pinned v5 package for Nixpad's existing TOML settings format.
    noctalia-nixpad.url =
      "github:noctalia-dev/noctalia/81f2c83d8e06d8d0398b0a268dc7e19766a9213f";

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

  outputs = {
    nixpkgs,
    nixpkgs-nixpad,
    nixpkgs-nixpad-unstable,
    apple-silicon,
    home-manager,
    home-manager-nixpad,
    chaotic,
    noctalia,
    noctalia-nixpad,
    ...
  }@inputs: rec {
    nixosConfigurations.mixi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./hosts/mixi/configuration.nix
        apple-silicon.nixosModules.apple-silicon-support

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          # Preserve any unmanaged file on the first Home Manager activation.
          home-manager.backupFileExtension = "hm-backup";
          home-manager.users.mixa = import ./home/mixa/home.nix;
        }
      ];
    };

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

    nixosConfigurations.nixpad =
      let
        system = "x86_64-linux";
        unstable = import nixpkgs-nixpad-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
      nixpkgs-nixpad.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit unstable;
          noctalia = noctalia-nixpad.packages.${system}.default;
        };
        modules = [
          ./hosts/nixpad/configuration.nix
          home-manager-nixpad.nixosModules.home-manager
          {
            # programs.bash starts managing ~/.bashrc when Starship is enabled.
            home-manager.backupFileExtension = "hm-backup";
          }
        ];
      };
  };
}
