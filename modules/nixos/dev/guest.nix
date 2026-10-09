# The development MicroVM guest. One runner serves every project: what is
# mounted where, the vsock CID and whether there is a network device are all
# decided at launch time by dev.sh (see extraArgsScript and dev-mounts).
{ cfg, inputs, system }:

inputs.nixpkgs-nixpad.lib.nixosSystem {
  inherit system;
  modules = [
    inputs.microvm.nixosModules.microvm
    ({ lib, pkgs, ... }: {
      networking = {
        hostName = "dev";
        useDHCP = false;
        useNetworkd = true;
        # Isolation is enforced on the host (passt runs as dev-net, which an
        # nftables table confines to the public internet). A guest firewall
        # would add nothing the guest could not remove.
        firewall.enable = false;
        # Public resolvers: the host's resolver is Tailscale MagicDNS, which
        # the dev-net user cannot reach anyway.
        nameservers = [ "1.1.1.1" "9.9.9.9" ];
      };
      services.resolved.enable = false;
      systemd.network = {
        enable = true;
        wait-online.enable = false;
        networks."10-uplink" = {
          matchConfig.Type = "ether";
          networkConfig.DHCP = "ipv4";
          dhcpV4Config = {
            UseDNS = false;
            UseDomains = false;
          };
          linkConfig.RequiredForOnline = "no";
        };
      };

      # The host connects over vsock. systemd-ssh-generator creates
      # sshd-vsock.socket when it sees a vsock device at boot, so the transport
      # has to be loaded before the generators run.
      boot.initrd.kernelModules = [ "vmw_vsock_virtio_transport" ];
      boot.kernelParams = [ "quiet" "udev.log_level=3" ];

      # Boot speed: systemd initrd with an uncompressed, minimal module set,
      # the systemd-native user/etc activation, and nothing a throwaway
      # headless VM does not need.
      boot.initrd.systemd.enable = true;
      boot.initrd.compressor = "cat";
      boot.initrd.includeDefaultModules = false;
      services.userborn.enable = true;
      system.etc.overlay.enable = true;
      services.nscd.enable = false;
      system.nssModules = lib.mkForce [ ];
      services.logrotate.enable = false;
      services.timesyncd.enable = false;
      services.udisks2.enable = false;
      boot.enableContainers = false;
      systemd.services."serial-getty@ttyS0".enable = false;
      systemd.services."autovt@".enable = false;
      systemd.oomd.enable = false;

      # microvm.nix registers the store closure in postBootCommands, before
      # systemd starts. Only in-guest nix needs it, so do it in the background
      # (still before nix-daemon).
      boot.postBootCommands = lib.mkForce "";
      systemd.services.dev-register-closure = {
        description = "Register the host-provided store closure";
        wantedBy = [ "multi-user.target" ];
        before = [ "nix-daemon.service" "nix-daemon.socket" ];
        after = [ "local-fs.target" ];
        serviceConfig.Type = "oneshot";
        script = ''
          if [[ "$(cat /proc/cmdline)" =~ regInfo=([^ ]*) ]]; then
            ${pkgs.nix}/bin/nix-store --load-db < "''${BASH_REMATCH[1]}"
          fi
        '';
      };
      systemd.sockets.nix-daemon.wants = [ "dev-register-closure.service" ];
      systemd.sockets.nix-daemon.after = [ "dev-register-closure.service" ];

      services.openssh = {
        enable = true;
        # No TCP listener: sshd.socket is socket-activated and then disabled
        # below, leaving only the generator's vsock socket.
        startWhenNeeded = true;
        openFirewall = false;
        hostKeys = [{ type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; }];
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = [ "dev" ];
          AuthorizedKeysFile = "/run/dev-host/authorized_keys";
          # The key lives on a read-only 9p share owned by the host user.
          StrictModes = false;
        };
      };
      systemd.sockets.sshd.wantedBy = lib.mkForce [ ];
      systemd.services.sshd-keygen.wantedBy = [ "multi-user.target" ];
      # The generated unit passes its own AuthorizedKeysFile (a systemd
      # credential); use sshd_config's instead.
      systemd.services."sshd-vsock@" = {
        wants = [ "sshd-keygen.service" ];
        after = [ "sshd-keygen.service" ];
        serviceConfig.ExecStart = [
          ""
          "-${pkgs.openssh}/bin/sshd -i -f /etc/ssh/sshd_config"
        ];
      };

      # No sudo: nothing in a dev VM needs root, and without it the read-only
      # bind mounts that dev-mounts places over .git/config and .git/hooks
      # cannot be undone from inside.
      security.sudo.enable = false;
      users.mutableUsers = false;
      # Root is deliberately unreachable.
      users.allowNoPasswordLogin = true;
      users.groups.dev.gid = 1000;
      users.users.dev = {
        isNormalUser = true;
        uid = 1000;
        group = "dev";
        home = "/home/dev";
        createHome = false;
        shell = pkgs.bashInteractive;
        # Rootless Podman: a uid range for container users, and a user
        # manager that outlives individual SSH sessions so containers do too.
        # (The uid ranges are written to /etc below: userborn does not
        # generate /etc/subuid.)
        linger = true;
      };
      # A mode makes these real files: newuidmap refuses symlinks.
      environment.etc."subuid" = { text = "dev:100000:65536\n"; mode = "0644"; };
      environment.etc."subgid" = { text = "dev:100000:65536\n"; mode = "0644"; };
      systemd.tmpfiles.rules = [ "d /home/dev 0700 dev dev -" ];

      # Docker-compatible containers without root: `docker` and
      # `docker compose` talk to the dev user's Podman socket. Images and
      # volumes live in the persistent home.
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
      systemd.user.sockets.podman.wantedBy = [ "sockets.target" ];

      nix.settings.experimental-features = [ "nix-command" "flakes" ];
      nixpkgs.config.allowUnfree = true;
      # Prebuilt binaries that expect a conventional distro (Playwright and
      # Puppeteer browsers, Electron, Prisma engines, binary npm/pip wheels)
      # find their libraries through nix-ld.
      programs.nix-ld = {
        enable = true;
        libraries = with pkgs; [
          stdenv.cc.cc
          zlib
          zstd
          bzip2
          xz
          openssl
          curl
          icu
          libuuid
          libxml2
          krb5
          expat
          glib
          nss
          nspr
          dbus
          systemd
          alsa-lib
          cups
          libdrm
          libgbm
          libGL
          libxkbcommon
          fontconfig
          freetype
          pango
          cairo
          atk
          at-spi2-atk
          at-spi2-core
          gtk3
          libsecret
          libnotify
          libx11
          libxcomposite
          libxdamage
          libxext
          libxfixes
          libxrandr
          libxcb
          libxshmfence
        ];
      };
      # Headless browsers need fonts for rendering and screenshots.
      fonts.enableDefaultPackages = true;
      programs.bash.completion.enable = true;
      documentation.enable = false;

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
        docker-compose
        kitty.terminfo
      ]) ++ (with inputs.llm-agents.packages.${system}; [
        claude-code
        codex
      ]);

      # Login shells (every dev session) pick up the host-provided env file
      # and git identity.
      environment.shellInit = ''
        if [ -r /run/dev-host/env ]; then
          set -a
          . /run/dev-host/env
          set +a
        fi
        export GIT_CONFIG_GLOBAL=/run/dev-host/gitconfig
        export DISABLE_AUTOUPDATER=1
        export DEV=1
        export DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"
        # File changes made on the host do not raise inotify events in the
        # guest, so dev servers poll instead (chokidar: Vite and most Node
        # tools; watchpack: webpack/Next.js).
        export CHOKIDAR_USEPOLLING=1
        export WATCHPACK_POLLING=true
      '';

      environment.interactiveShellInit = ''
        dev_prompt() {
          local rc="$?"
          local project="''${DEV_PROJECT:-dev}"
          local branch=""
          local arrow_color="32"
          if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true)"
          fi
          [ "$rc" -eq 0 ] || arrow_color="31"
          PS1="\[\e[1;35m\]◆ dev\[\e[0m\] · \[\e[1;36m\]''${project}\[\e[0m\]"
          [ -z "$branch" ] || PS1+=" · \[\e[1;33m\]''${branch}\[\e[0m\]"
          PS1+=" \[\e[2m\]\w\[\e[0m\] \[\e[1;''${arrow_color}m\]❯\[\e[0m\] "
          printf '\033]0;DEV — %s\007' "$project"
        }
        PROMPT_COMMAND=dev_prompt
      '';

      # Claude Code: file edits and shell commands run without prompting (the
      # VM is the sandbox), but destructive or remote commands still ask.
      # "ask" rules take precedence over "allow".
      environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
        permissions = {
          defaultMode = "acceptEdits";
          allow = [ "Bash" ];
          ask = map (cmd: "Bash(${cmd}:*)") [
            "rm"
            "rmdir"
            "shred"
            "unlink"
            "dd"
            "mkfs"
            "ssh"
            "scp"
            "sftp"
            "rsync"
            "git push"
            "git reset --hard"
            "git clean"
            "git checkout --"
            "git restore"
            "git branch -D"
            "git stash drop"
          ];
        };
      };

      # A rootless virtiofsd cannot use file handles, so it holds one host fd
      # for every inode the guest has cached, up to its 524288 limit. The guest
      # sees the host's whole /nix/store and only evicts cached inodes under
      # memory pressure, so one walk of the store would exhaust the daemon and
      # every later file open fails with ENFILE. Dropping unused dentries and
      # inodes makes the guest send FORGET, which releases the host fds.
      systemd.services.dev-inode-reclaim = {
        description = "Release cached virtiofs inodes";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.Restart = "always";
        script = ''
          while sleep 3; do
            read -r inodes _ < /proc/sys/fs/inode-nr
            if [ "$inodes" -gt 150000 ]; then
              echo 2 > /proc/sys/vm/drop_caches
            fi
          done
        '';
      };

      # Codex's shared background server expects the official installer's
      # package layout and refuses to start from the Nix package.
      environment.etc."codex/config.toml".text = ''
        [features]
        daemon_auto_start = false
      '';

      # Mount the project and any granted folders at the same paths as on the
      # host, protect git's executable configuration, then signal readiness.
      # /run/dev-host/mounts lines: <tag>\t<rw|ro>\t<path>
      # /run/dev-host/protect lines: <path> to bind read-only
      systemd.services.dev-mounts = {
        description = "Mount development workspace shares";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
        path = [ pkgs.util-linux pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          while IFS=$'\t' read -r tag mode target; do
            [ -n "$tag" ] || continue
            mkdir -p "$target"
            opts=defaults
            [ "$mode" = ro ] && opts=ro
            mount -t virtiofs -o "$opts" "$tag" "$target"
          done < /run/dev-host/mounts

          if [ -r /run/dev-host/protect ]; then
            while IFS= read -r target; do
              [ -e "$target" ] || continue
              mount --bind "$target" "$target"
              mount -o remount,bind,ro "$target"
            done < /run/dev-host/protect
          fi

          if [ ! -e /home/dev/.claude.json ]; then
            echo '{"hasCompletedOnboarding":true}' > /home/dev/.claude.json
            chown dev:dev /home/dev/.claude.json
          fi

          touch /run/dev-ready
        '';
      };


      microvm = {
        hypervisor = "qemu";
        vcpu = cfg.cpus;
        mem = cfg.memoryMB;
        # QMP socket, used by the launcher for an ACPI power-down.
        socket = "control.sock";
        optimize.enable = true;
        # Boot log goes to vm.log in the project's state directory.
        qemu.serialConsole = true;
        interfaces = [ ];

        # Runtime devices, from the launcher's environment:
        #   DEV_CID     vsock CID (unique per project)
        #   DEV_NET     1 = connect to the host's passt socket
        #   DEV_SHARES  virtiofs tags; each has a <tag>.sock in the cwd
        extraArgsScript = toString (pkgs.writeShellScript "dev-qemu-runtime-args" ''
          set -eu
          [[ "''${DEV_CID:-}" =~ ^[0-9]+$ ]] || { echo "DEV_CID is missing" >&2; exit 1; }
          args="-device vhost-vsock-pci,guest-cid=$DEV_CID"
          if [ "''${DEV_NET:-0}" = 1 ]; then
            args+=" -netdev stream,id=net0,server=off,addr.type=unix,addr.path=/run/dev-net/passt.sock"
            args+=" -device virtio-net-pci,netdev=net0,mac=02:00:00:00:00:01,romfile="
          fi
          i=0
          for tag in ''${DEV_SHARES:-}; do
            args+=" -chardev socket,id=dfs$i,path=$tag.sock"
            args+=" -device vhost-user-fs-pci,chardev=dfs$i,tag=$tag"
            i=$((i + 1))
          done
          printf '%s\n' "$args"
        '');

        shares = [
          {
            tag = "ro-store";
            source = "/nix/store";
            mountPoint = "/nix/.ro-store";
            proto = "virtiofs";
            readOnly = true;
          }
          {
            # Launch metadata written by dev.sh: SSH key, mount list, env.
            tag = "dev-host";
            source = "host";
            mountPoint = "/run/dev-host";
            proto = "9p";
            securityModel = "none";
            readOnly = true;
          }
        ];

        volumes = [
          {
            # Per-project persistent home: caches, agent state and history.
            image = "home.img";
            mountPoint = "/home/dev";
            size = cfg.homeSizeMB;
            fsType = "ext4";
          }
          {
            # Recreated on every boot.
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
}
