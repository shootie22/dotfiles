{
  description = "Reproducible NixOS configurations for mixi, nixpad, workstation, fuji and edge";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-lima = {
      url = "github:nixos-lima/nixos-lima";
      inputs.nixpkgs.follows = "nixpkgs";
    };


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

    # Hypervisor plumbing for the `dev` MicroVMs (modules/nixos/dev). The
    # guest runs on nixpkgs-nixpad, so microvm.nix follows it.
    microvm = {
      url = "github:microvm-nix/microvm.nix/0d49083ba2d7419b22908ac392777c16df9a032e";
      inputs.nixpkgs.follows = "nixpkgs-nixpad";
    };

    # Secrets for the server hosts.
    sops-nix.url = "github:Mic92/sops-nix";

    # GitOps for the servers: each one pulls this repo and switches to its own
    # config (infrastructure repo, docs/ha/decisions.md).
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Declarative disk layouts, used by nixos-anywhere to install the edge.
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Twintail Launcher — multi-platform anime game launcher with NixOS support.
    twintail = {
      url = "github:Yuna404/TwintailFlake/8b744bc5dbcd594fa7e245f2922c6da5679f3e52";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Cube Calendar — native GTK CalDAV calendar.
    cube-calendar = {
      url = "git+https://git.yeetus.net/radu/cube-calendar.git?rev=9a59f4e548224b0ee4030903741c50f288e82c76";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    nix-darwin,
    nixos-lima,
    nixpkgs-nixpad,
    nixpkgs-nixpad-unstable,
    apple-silicon,
    home-manager,
    home-manager-nixpad,
    chaotic,
    noctalia,
    noctalia-nixpad,
    sops-nix,
    disko,
    comin,
    twintail,
    cube-calendar,
    ...
  }@inputs: rec {
    darwinConfigurations.minima = nix-darwin.lib.darwinSystem {
      modules = [
        ./hosts/minima/configuration.nix
      ];
    };

    nixosConfigurations.minima-vm = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        nixos-lima.nixosModules.lima
        sops-nix.nixosModules.sops
        comin.nixosModules.comin
        ./hosts/minima-vm/configuration.nix
      ];
    };

    packages.aarch64-linux.antigravity-cli =
      (import nixpkgs {
        system = "aarch64-linux";
        config.allowUnfree = true;
      }).callPackage ./pkgs/antigravity-cli { };

    # VM rehearsal of the move to etcd (infrastructure Phase 3, tests/etcd-migration.nix).
    checks.x86_64-linux.etcd-migration = import ./tests/etcd-migration.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      k3sPackage = nixosConfigurations.fuji.config.services.k3s.package;
    };

    # VM rehearsal of the Nebula backbone (infrastructure #141, tests/nebula-backbone.nix).
    checks.x86_64-linux.nebula-backbone = import ./tests/nebula-backbone.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    # VM rehearsal of Phase 3 on Nebula, down to a cold start without the tailnet
    # (infrastructure #20-#26, #141; tests/etcd-over-nebula.nix).
    checks.x86_64-linux.etcd-over-nebula = import ./tests/etcd-over-nebula.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      k3sPackage = nixosConfigurations.fuji.config.services.k3s.package;
    };

    # Tailscale stays off the Nebula mesh (modules/nixos/nebula-mesh.nix).
    checks.x86_64-linux.tailscale-off-nebula = import ./tests/tailscale-off-nebula.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    # Phase 4: Postgres with CloudNativePG, one instance per site
    # (infrastructure #28-#33; tests/cnpg-across-sites.nix).
    checks.x86_64-linux.cnpg-across-sites = import ./tests/cnpg-across-sites.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      k3sPackage = nixosConfigurations.fuji.config.services.k3s.package;
    };

    # Standby copies of service folders between the sites
    # (infrastructure #142; tests/standby-copy.nix).
    checks.x86_64-linux.standby-copy = import ./tests/standby-copy.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    # Services with files failing over between the sites
    # (infrastructure Phase 6; tests/site-failover.nix).
    checks.x86_64-linux.site-failover = import ./tests/site-failover.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      k3sPackage = nixosConfigurations.fuji.config.services.k3s.package;
    };

    # A deploy that cuts a host off gets rolled back by itself
    # (infrastructure incident 2026-10-14; tests/switch-guard.nix).
    checks.x86_64-linux.switch-guard = import ./tests/switch-guard.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    # A Kata VM's memory fits in /dev/shm: mixi's CI VMs died without it
    # (infrastructure #300; tests/kata-shm.nix).
    checks.x86_64-linux.kata-shm = import ./tests/kata-shm.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    };

    # Staged deploys: the gate that lets a later host deploy a commit only
    # after its upstream hosts have run it (tests/deploy-gate.sh). No VMs.
    checks.x86_64-linux.deploy-gate =
      let pkgs = nixpkgs.legacyPackages.x86_64-linux;
      in pkgs.runCommand "deploy-gate-test" {
        nativeBuildInputs = with pkgs; [ bash python3 jq curl coreutils gnugrep ];
        GATE_SCRIPT = ./modules/nixos/deploy-stages/gate.sh;
      } ''
        bash ${./tests/deploy-gate.sh}
        touch $out
      '';

    # The failover checker's view of RO: Traefik answering isn't enough, fuji
    # must reach the cluster too (infrastructure incident 2026-10-14;
    # tests/failover-checker.py). No VMs, a few seconds.
    checks.x86_64-linux.failover-checker =
      let pkgs = nixpkgs.legacyPackages.x86_64-linux;
      in pkgs.runCommand "failover-checker-test" {
        nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.dnspython ])) ];
        CHECKER = ./modules/nixos/failover-checker/checker.py;
      } ''
        python3 ${./tests/failover-checker.py}
        touch $out
      '';

    # The front door in front of Traefik (modules/nixos/front-door.nix):
    # Traefik restarts under traffic without a failed request.
    checks.x86_64-linux.front-door = import ./tests/front-door.nix {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      k3sPackage = nixosConfigurations.fuji.config.services.k3s.package;
    };

    # site-failover's decisions: what counts as a holder that can't run a
    # service (infrastructure incident 2026-10-20), where each database
    # belongs and when it's moved (decision 2026-10-21), which pods are
    # strays. No VMs, a second (tests/site-failover-unit.py).
    checks.x86_64-linux.site-failover-unit =
      let pkgs = nixpkgs.legacyPackages.x86_64-linux;
      in pkgs.runCommand "site-failover-unit-test" {
        nativeBuildInputs = [ pkgs.python3 ];
        SITE_FAILOVER = ./modules/nixos/site-failover/site-failover.py;
      } ''
        python3 ${./tests/site-failover-unit.py}
        touch $out
      '';

    nixosConfigurations.mixi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./hosts/mixi/configuration.nix
        apple-silicon.nixosModules.apple-silicon-support
        sops-nix.nixosModules.sops
        comin.nixosModules.comin

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
        ./modules/nixos/dev
        {
          modules.dev = {
            enable = true;
            user = "nixa";
            # 22c/44t, 64 GB. RAM and disk are only used as the guest
            # touches them; RAM is returned when the VM stops.
            cpus = 44;
            memoryMB = 16384;
            homeSizeMB = 131072;
            storeOverlaySizeMB = 32768;
          };
        }
        # A CI runner while the workstation is on: one throwaway VM per job
        # (modules/nixos/ci-runner-vm, infrastructure ci-runner).
        ./modules/nixos/ci-runner-vm
        {
          dotfiles.ciRunnerVm = {
            enable = true;
            cpus = 16;
            memoryMB = 16384;
            labels = [ "linux-amd64" "linux-amd64-workstation" ];
          };
        }
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

    nixosConfigurations.fuji = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/fuji/configuration.nix
        sops-nix.nixosModules.sops
        comin.nixosModules.comin

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.fuji = import ./home/fuji/home.nix;
        }
      ];
    };

    # Not installed yet: Debian until the reinstall (infrastructure #18).
    nixosConfigurations.thinkcentre = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/thinkcentre/configuration.nix
        sops-nix.nixosModules.sops
        comin.nixosModules.comin
      ];
    };

    # Rehearsal VM for the thinkcentre migration (hosts/thinkcentre/rehearsal).
    nixosConfigurations.thinkcentre-rehearsal = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hosts/thinkcentre/rehearsal
        disko.nixosModules.disko
      ];
    };

    nixosConfigurations.edge = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        comin.nixosModules.comin
        sops-nix.nixosModules.sops
        ./hosts/edge/configuration.nix
      ];
    };

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
          inherit unstable inputs;
          noctalia = noctalia-nixpad.packages.${system}.default;
        };
        modules = [
          ./hosts/nixpad/configuration.nix
          ./modules/nixos/dev
          {
            modules.dev = {
              enable = true;
              user = "bro";
            };
          }
          home-manager-nixpad.nixosModules.home-manager
          {
            # Preserve the existing Starship config and prior .hm-backup file
            # when Home Manager starts managing the shared Bash prompt.
            home-manager.backupFileExtension = "hm-backup-previous";
          }
        ];
      };
  };
}
