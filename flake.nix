{
  description = "NixOS + Home Manager configuration for nixpad and desktop";

  inputs = {
    # Pinned by flake.lock. Update deliberately with `nix flake update`
    # (or `nix flake update nixpkgs` for a single input) and commit the
    # resulting lock change, so a channel moving under us shows up as a
    # reviewable diff instead of a surprise at rebuild time.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      # Keep home-manager evaluating against the same nixpkgs as the system,
      # instead of pulling a second copy.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Noctalia pinned to v5: nixos-unstable is still on 4.7.x, which uses the
    # old settings.json format and can't read our v5
    # ~/.local/state/noctalia/settings.toml. Switch to
    # unstable.noctalia-shell (and drop this input) once the channel reaches
    # >= 5.0.0.
    noctalia.url =
      "github:noctalia-dev/noctalia/81f2c83d8e06d8d0398b0a268dc7e19766a9213f";
  };

  outputs = { nixpkgs, nixpkgs-unstable, home-manager, noctalia, ... }:
    let
      system = "x86_64-linux";

      # A few packages come from nixos-unstable while the rest of the system
      # tracks stable. Mirrors the nixpkgs.config the hosts set, since this
      # instance is imported separately from the system's own pkgs.
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };

      mkHost = hostName: nixpkgs.lib.nixosSystem {
        inherit system;

        # Reaches every NixOS module, replacing the per-host `_module.args`.
        specialArgs = {
          inherit unstable;
          noctalia = noctalia.packages.${system}.default;
        };

        modules = [
          ./hosts/${hostName}/configuration.nix
          home-manager.nixosModules.home-manager
        ];
      };
    in
    {
      nixosConfigurations = {
        nixpad = mkHost "nixpad";
        desktop = mkHost "desktop";
      };
    };
}
