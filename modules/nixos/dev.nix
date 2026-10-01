# Disposable development MicroVMs.
# microvm.nix owns the hypervisor plumbing; this module only defines the
# hardened guest image and the small `dev` launcher UX.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.modules.dev;
  system = pkgs.stdenv.hostPlatform.system;

  # Pin microvm.nix independently of the host flake lock. This keeps the
  # integration reproducible without coupling its nixpkgs input to the host.
  microvmSrc = builtins.fetchTree {
    type = "github";
    owner = "microvm-nix";
    repo = "microvm.nix";
    rev = "0d49083ba2d7419b22908ac392777c16df9a032e";
    narHash = "sha256-ZHsxoYXXnfJtMVh1/yY+1Eh9hHcPBhE28Qvinauh+BQ=";
  };
  microvmModule = import "${microvmSrc.outPath}/nixos-modules/microvm";

  agentPackages = inputs.llm-agents.packages.${system};

  guest = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      microvmModule
      ({ pkgs, ... }: {
        networking = {
          hostName = "dev";
          useDHCP = true;
          enableIPv6 = false;
          firewall = {
            enable = true;
            logRefusedConnections = false;
            # QEMU user networking has no inbound path unless the launcher
            # explicitly creates a hostfwd. The only one is random localhost
            # -> guest:22, so opening guest SSH here does not expose it to LAN.
            allowedTCPPorts = [ 22 ];
          };
        };

        users.users.dev = {
          isNormalUser = true;
          uid = 1000;
          home = "/home/dev";
          createHome = true;
          shell = pkgs.bashInteractive;
          extraGroups = [ "wheel" ];
        };
        security.sudo.wheelNeedsPassword = false;

        services.openssh = {
          enable = true;
          openFirewall = false;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "no";
            AllowUsers = [ "dev" ];
            AuthorizedKeysFile = "/run/dev-host/authorized_keys";
            # This is a read-only 9p share containing only a public key.
            StrictModes = false;
          };
        };

        nix.settings = {
          experimental-features = [ "nix-command" "flakes" ];
          trusted-users = [ "root" "dev" ];
        };
        nixpkgs.config.allowUnfree = true;

        programs.nix-ld.enable = true;
        programs.bash.completion.enable = true;

        environment.systemPackages = (with pkgs; [
          bashInteractive
          coreutils
          curl
          wget
          git
          gnumake
          gcc
          clang
          cmake
          pkg-config
          python3
          nodejs
          rustc
          cargo
          ripgrep
          fd
          jq
          unzip
          zip
          less
          tmux
          shellcheck
          sqlite
          openssl
          which
          file
          gnused
          gawk
          gnugrep
          findutils
          iproute2
          procps
          lsof
          strace
          tree
          nftables
        ]) ++ [
          agentPackages.claude-code
          agentPackages.codex
        ];

        environment.etc."profile.d/dev.sh".text = ''
          export DEV=1
          if [[ $- == *i* ]]; then
            dev_prompt() {
              local rc="$?"
              local repo="''${DEV_REPO:-work}"
              local branch=""
              local place="''${PWD#/work}"
              local arrow_color="32"
              [ -n "$place" ] || place="/"
              if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true)"
              fi
              [ "$rc" -eq 0 ] || arrow_color="31"
              PS1="\[\e[1;35m\]◆ dev\[\e[0m\] · \[\e[1;36m\]''${repo}\[\e[0m\]"
              [ -z "$branch" ] || PS1+=" · \[\e[1;33m\]''${branch}\[\e[0m\]"
              [ "$place" = "/" ] || PS1+=" · \[\e[2m\]''${place}\[\e[0m\]"
              PS1+=" \[\e[1;''${arrow_color}m\]❯\[\e[0m\] "
              printf '\033]0;DEV — %s\007' "$repo"
            }
            PROMPT_COMMAND=dev_prompt
          fi
        '';

        systemd.tmpfiles.rules = [
          "d /persist/claude 0700 dev users -"
          "d /persist/codex 0700 dev users -"
          "L+ /home/dev/.claude - - - - /persist/claude"
          "L+ /home/dev/.codex - - - - /persist/codex"
        ];

        # Public internet is allowed, but guest-initiated access to the host,
        # LAN, link-local networks, and Tailscale/CGNAT ranges is rejected.
        # QEMU's DNS/DHCP endpoints are the only private-address exceptions.
        systemd.services.dev-egress-firewall = {
          description = "Restrict development MicroVM egress to public networks";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          before = [ "dev-ready.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ${pkgs.nftables}/bin/nft delete table inet dev_egress 2>/dev/null || true
            ${pkgs.nftables}/bin/nft -f - <<'NFT'
            table inet dev_egress {
              chain output {
                type filter hook output priority 0; policy accept;
                ct state established,related accept
                oifname "lo" accept
                ip daddr 10.0.2.3 udp dport 53 accept
                ip daddr 10.0.2.3 tcp dport 53 accept
                ip daddr 10.0.2.2 udp dport 67 accept
                ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } reject
              }
            }
            NFT
          '';
        };

        systemd.services.dev-ready = {
          description = "Signal that the development MicroVM is ready";
          wantedBy = [ "multi-user.target" ];
          requires = [ "dev-egress-firewall.service" ];
          after = [
            "dev-egress-firewall.service"
            "systemd-tmpfiles-setup.service"
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            ${pkgs.coreutils}/bin/touch /run/dev-ready
          '';
        };

        microvm = {
          hypervisor = "qemu";
          vcpu = cfg.cpus;
          mem = cfg.memoryMB;
          socket = "control.sock";
          optimize.enable = true;
          qemu.serialConsole = false;

          # The launcher supplies a random localhost SSH host-forward at runtime.
          # Keeping networking out of the static runner means one runner can be
          # launched concurrently from many per-project working directories.
          interfaces = [ ];
          extraArgsScript = pkgs.writeShellScript "dev-qemu-runtime-args" ''
            if ! [[ "''${DEV_SSH_PORT:-}" =~ ^[0-9]+$ ]]; then
              echo "DEV_SSH_PORT is missing or invalid" >&2
              exit 1
            fi
            printf '%s\n' "-netdev user,id=net0,hostfwd=tcp:127.0.0.1:''${DEV_SSH_PORT}-:22 -device virtio-net-pci,netdev=net0,mac=02:00:00:00:10:00,romfile="
          '';

          # Relative paths resolve from the launcher's per-project state dir.
          # The launcher starts rootless virtiofsd for the repo socket itself.
          shares = [
            {
              tag = "repo";
              source = "repo";
              mountPoint = "/work";
              proto = "virtiofs";
              readOnly = false;
            }
            {
              tag = "hostkey";
              source = "ssh";
              mountPoint = "/run/dev-host";
              proto = "9p";
              securityModel = "none";
              readOnly = true;
            }
          ];

          volumes = [
            {
              image = "agent-state.img";
              mountPoint = "/persist";
              size = cfg.stateSizeMB;
              fsType = "ext4";
            }
            {
              image = "nix-rw.img";
              mountPoint = "/nix/.rw-store";
              size = cfg.storeOverlaySizeMB;
              fsType = "ext4";
            }
          ];
          writableStoreOverlay = "/nix/.rw-store";
        };

        system.stateVersion = "26.05";
      })
    ];
  };

  runner = guest.config.microvm.declaredRunner;

  runtimeInputs = with pkgs; [
    coreutils
    findutils
    gawk
    git
    iproute2
    openssh
    util-linux
    virtiofsd
  ];

  dev = pkgs.writeShellScriptBin "dev" ''
    export PATH=${lib.makeBinPath runtimeInputs}:$PATH
    export DEV_RUNNER=${lib.escapeShellArg (toString runner)}
    exec ${pkgs.bash}/bin/bash ${../../scripts/dev.sh} "$@"
  '';
in
{
  options.modules.dev = {
    enable = lib.mkEnableOption "disposable development MicroVMs";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Host user allowed to launch development MicroVMs.";
    };

    cpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Virtual CPUs per development MicroVM.";
    };

    memoryMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "RAM in MiB per development MicroVM.";
    };

    stateSizeMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "Persistent Claude/Codex state volume size in MiB per repo.";
    };

    storeOverlaySizeMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16384;
      description = "Disposable writable Nix store overlay size in MiB.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "modules.dev.user must name an existing NixOS user";
      }
    ];

    environment.systemPackages = [ dev ];
    users.users.${cfg.user}.extraGroups = [ "kvm" ];
  };
}
