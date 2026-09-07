# home-manager configuration for nixa.
{ config, lib, pkgs, inputs, ... }:

{
  imports = [ inputs.noctalia.homeModules.default ];

  home.stateVersion = "26.05";

  # The editable checkout used by package/cookie helpers and nh.
  home.sessionVariables = {
    NIXOS_CONFIG = "${config.home.homeDirectory}/git/dotfiles";
    NH_FLAKE = "${config.home.homeDirectory}/git/dotfiles#workstation";
  };

  # Plain packages live in packages.txt so `nix-addpkg` can manage them.
  # Anything needing an override or a wrapper is spelled out here instead.
  home.packages = (import ../../lib/read-packages.nix {
    inherit lib pkgs;
    file = ./packages.txt;
  }) ++ (with pkgs; [
    # Matrix client. Electron can't auto-detect the keyring under "Hyprland",
    # so point it at the gnome-keyring (libsecret) backend explicitly.
    (element-desktop.override { commandLineArgs = "--password-store=gnome-libsecret"; })

    # Matrix client with Element Call voice/video rooms. Two fixes are needed
    # on top of the nixpkgs package:
    #
    # 1. Cinny is a Tauri app, so its webview is WebKitGTK — which nixpkgs
    #    builds with ENABLE_EXPERIMENTAL_FEATURES=OFF, and that flag gates
    #    ENABLE_WEB_RTC. Without it Cinny says "your browser does not support
    #    WebRTC". The experimental build is in the binary cache, so enabling
    #    it costs a download rather than a WebKit compile.
    #
    # 2. WebKitGTK's WebRTC is backed by GStreamer, but the stock wrapper puts
    #    only Tauri's asset plugin on GST_PLUGIN_SYSTEM_PATH_1_0. Without the
    #    real plugin sets, RTCRtpSender.getCapabilities('video') returns *no
    #    codecs* and addTransceiver throws InvalidAccessError, so joining a
    #    call fails. Adding them yields H264/VP8/VP9.
    ((cinny-desktop.override {
      webkitgtk_4_1 = webkitgtk_4_1.override { enableExperimental = true; };
    }).overrideAttrs (old: {
      preFixup = (old.preFixup or "") + ''
        gappsWrapperArgs+=(
          --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${lib.makeSearchPath "lib/gstreamer-1.0" (with gst_all_1; [
            gstreamer gst-plugins-base gst-plugins-good
            gst-plugins-bad gst-plugins-ugly gst-libav
          ])}"
        )
      '';
    }))
    # AI plan quota (Claude, Codex, ...): `ai-usagebar` prints/serves the
    # numbers, `ai-usagebar-tui` is the full-screen dashboard. Comes from a
    # flake input rather than nixpkgs, so it cannot live in packages.txt.
    inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.codex

    (writeShellApplication {
      name = "screenrecord-toggle";
      runtimeInputs = [ slurp wl-screenrec wl-clipboard libnotify util-linux coreutils ];
      text = builtins.readFile ./hypr/screenrecord.sh;
    })
    (writeShellApplication {
      name = "cookie-allow";
      runtimeInputs = [ gnugrep coreutils git ];
      text = builtins.readFile ../../scripts/cookie-allow.sh;
    })
    (writeShellApplication {
      name = "nix-addpkg";
      runtimeInputs = [ nix gnugrep gnused gawk coreutils git ];
      text = builtins.readFile ../../scripts/nix-addpkg.sh;
    })
  ]);

  # Pictures/Videos live on the media drive (~/localstorage). Point XDG straight
  # at them, and symlink ~/Pictures + ~/Videos there too so apps that hardcode
  # those paths also write to the drive. No auto-create: if the drive isn't
  # mounted, writes fail loudly instead of making a stray local copy.
  xdg.userDirs = {
    enable = true;
    createDirectories = false;
    pictures = "${config.home.homeDirectory}/localstorage/Media/Pictures";
    videos   = "${config.home.homeDirectory}/localstorage/Media/Videos";
  };
  home.file."Pictures".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/localstorage/Media/Pictures";
  home.file."Videos".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/localstorage/Media/Videos";

  # grimblast reads XDG_SCREENSHOTS_DIR (via user-dirs.dirs). Point it at
  # ~/Pictures/Screenshots so shots land on the media drive. (recordings ->
  # Videos/Recordings is handled in screenrecord.sh)
  xdg.userDirs.extraConfig.SCREENSHOTS =
    "${config.home.homeDirectory}/Pictures/Screenshots";

  # Terminal ----------------------------------------------------------------
  programs.kitty = {
    enable = true;
    font = { name = "JetBrainsMono Nerd Font"; size = 11; };
    settings = {
      background_opacity = "0.80";
      confirm_os_window_close = 0;      # no close-confirmation prompt
      window_padding_width = 6;
    };
  };

  programs.bash = {
    enable = true;

    # kitty sets TERM=xterm-kitty, and that terminfo entry only exists where
    # kitty is installed — so ncurses programs (nano, htop) die on a remote
    # host that has never seen it. `kitten ssh` ships the entry over on
    # connect, keeping kitty's full capabilities instead of downgrading TERM.
    # Aliases are interactive-only, so scripts, git and rsync still get plain
    # ssh; `command ssh` bypasses it for a host where the copy fails.
    shellAliases.ssh = "kitten ssh";
  };

  # Prompt — Starship. One line, dot separators, segments appear only when
  # relevant: user · path · git(branch*↑↓, rebase state) · ❄nix · duration ·
  # ✗code · ❯ (green ok / red fail). SSH host shown only when remote.
  programs.starship = {
    enable = true;
    settings = {
      add_newline = false;

      format = lib.concatStrings [
        "$username" "$hostname" "$directory"
        "$git_branch" "$git_status" "$git_state"
        "$nix_shell" "$cmd_duration" "$jobs" "$status" "$character"
      ];

      username = {
        show_always = true;
        format = "[$user]($style)";
        style_user = "bold cyan";
        style_root = "bold red";
      };

      hostname = {
        ssh_only = true;
        format = "[ · ](dimmed)[$hostname]($style)";
        style = "bold yellow";
      };

      directory = {
        format = "[ · ](dimmed)[$path]($style)[$read_only]($read_only_style)";
        style = "bold blue";
        truncation_length = 3;
        truncation_symbol = "…/";
        truncate_to_repo = false;
        read_only = " ";
        read_only_style = "yellow";
      };

      git_branch = {
        format = "[ · ](dimmed)[$branch]($style)";
        style = "bold magenta";
      };
      git_status = {
        format = "( [$all_status$ahead_behind]($style))";
        style = "yellow";
        conflicted = "[=\${count}](bold red)";
        untracked  = "[?\${count}](blue)";
        modified   = "[*\${count}](yellow)";
        staged     = "[+\${count}](green)";
        renamed    = "[»\${count}](yellow)";
        deleted    = "[✘\${count}](red)";
        stashed    = "[≡\${count}](dimmed)";
        ahead      = "[↑\${count}](cyan)";
        behind     = "[↓\${count}](cyan)";
        diverged   = "[↑\${ahead_count}↓\${behind_count}](bold red)";
      };
      git_state = {
        format = "[ · ](dimmed)[\\($state $progress_current/$progress_total\\)]($style)";
        style = "bold yellow";
      };

      nix_shell = {
        format = "[ · ](dimmed)[$symbol$state]($style)";
        symbol = "❄ ";
        style = "bold blue";
        impure_msg = "impure";
        pure_msg = "pure";
        unknown_msg = "nix";
      };

      cmd_duration = {
        format = "[ · ](dimmed)[$duration]($style)";
        style = "yellow";
        min_time = 2000;
      };

      jobs = {
        format = "[ · ](dimmed)[$symbol$number]($style)";
        symbol = "✦";
        style = "bold blue";
        number_threshold = 1;
      };

      status = {
        disabled = false;
        format = "[ · ](dimmed)[$symbol$status]($style)";
        symbol = "✗";
        style = "bold red";
      };

      character = {
        format = "[ · ](dimmed)[$symbol]($style) ";
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };
    };
  };

  programs.btop.enable = true;

  # Browser -------------------------------------------------------------
  programs.librewolf = {
    enable = true;
    # Sites allowed to keep cookies (stay logged in past a restart). The list
    # lives in ./librewolf-cookie-allow.txt — add entries with `cookie-allow <url>`.
    policies.Cookies.Allow =
      lib.filter (lib.hasPrefix "https://")
        (lib.splitString "\n" (builtins.readFile ./librewolf-cookie-allow.txt));
  };

  # Cursor — dark, classic pointer shapes --------------------------------
  home.pointerCursor = {
    enable = true;
    name = "Vanilla-DMZ-AA";
    package = pkgs.vanilla-dmz;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  # Unified dark theme across toolkits ---------------------------------
  # GTK 2/3/4 + libadwaita
  gtk = {
    enable = true;
    theme = { name = "Adwaita-dark"; package = pkgs.gnome-themes-extra; };
    iconTheme = { name = "Papirus-Dark"; package = pkgs.papirus-icon-theme; };
  };
  dconf.settings."org/gnome/desktop/interface" = {
    color-scheme = "prefer-dark";
    gtk-theme = "Adwaita-dark";
  };

  # Qt 5/6 — KDE platform theme + Breeze Dark KColorScheme so KDE apps
  # (Dolphin) get a readable dark palette, not just a dark widget style.
  qt = {
    enable = true;
    platformTheme.name = "kde";
    style.name = "breeze";
  };
  xdg.configFile."kdeglobals".text = ''
    ${builtins.readFile "${pkgs.kdePackages.breeze}/share/color-schemes/BreezeDark.colors"}

    [Icons]
    Theme=Papirus-Dark

    [General]
    TerminalApplication=kitty
  '';

  # Noctalia shell ------------------------------------------------------
  programs.noctalia = {
    enable = true;
    systemd.enable = true;            # started with the graphical session
    settings = {
      theme.mode = "dark";

      shell = {
        corner_radius_scale = 0.0;    # square corners everywhere
        font_family = "Inter";
        launch_apps_as_systemd_services = true;
        setup_wizard_enabled = false;
      };

      # Top bar: swap the numbered workspace switcher for a per-workspace
      # app-icon taskbar; scroll anywhere on the bar to change workspace.
      bar.default = {
        position = "top";
        start    = [ "launcher" "wallpaper" "taskbar" ];
        # Noctalia's stock `end` list, with the AI-usage capsule in front of it.
        # Spelled out because setting `end` replaces the default rather than
        # extending it — keep the tail in sync if upstream adds a widget.
        end = [
          "ai_usage" "ai_usage_agy" "ai_usage_codex"
          "media" "tray" "notifications" "clipboard" "network" "bluetooth"
          "volume" "brightness" "battery" "control-center" "session"
        ];
        actions.scroll_up   = "workspace-switch prev";
        actions.scroll_down = "workspace-switch next";
        dead_zone.actions.scroll_up   = "workspace-switch prev";
        dead_zone.actions.scroll_down = "workspace-switch next";
      };

      # AI plan quota in the bar. The plugin only runs `ai-usagebar usage
      # --json` and draws it; credentials stay with the CLI (see
      # ~/.config/ai-usagebar/config.toml, deliberately not managed here so
      # keys never land in the nix store).
      plugins.enabled = [ "felipeartur/ai-usagebar" ];
      plugin_settings."felipeartur/ai-usagebar".refresh_minutes = 5;

      # One named instance per plan, rather than a single "auto" capsule that
      # silently swaps which plan it is showing. Names are on because two
      # pinned capsules otherwise look identical.
      #
      # Antigravity has no credential of its own: ai-usagebar reads the quota
      # off whatever Antigravity process is running locally (`agy`, or the
      # IDE). With nothing running there is no server to ask, so this capsule
      # sits in its error state between sessions — expected, not a misconfig.
      widget.ai_usage = {
        type = "felipeartur/ai-usagebar:bar";
        vendor = "anthropic";
        show_name = true;
        visualization = "gauge";   # quota bar over a thinner window-elapsed bar
        extras = "countdown";      # time left in the window
      };
      widget.ai_usage_agy = {
        type = "felipeartur/ai-usagebar:bar";
        vendor = "antigravity";
        show_name = true;
        visualization = "gauge";
        extras = "countdown";
      };
      widget.ai_usage_codex = {
        type = "felipeartur/ai-usagebar:bar";
        vendor = "codex";
        show_name = true;
        visualization = "gauge";
        extras = "countdown";
      };

      widget.taskbar = {
        group_by_workspace        = true;
        workspace_group_content   = "icons";
        group_single_icon_per_app = true;
        show_workspace_label      = false;   # icons, not "1 2 3 4"
        hide_empty_workspaces     = false;
        show_active_indicator     = true;
        actions.scroll_up   = "workspace-switch prev";
        actions.scroll_down = "workspace-switch next";
      };

      # Render the live palette into a Hyprland colour file and reload.
      theme.templates.user.hyprland = {
        input_path  = "$XDG_CONFIG_HOME/noctalia/templates/hyprland.lua";
        output_path = "$XDG_CONFIG_HOME/hypr/noctalia-colors.lua";
        post_hook   = "hyprctl reload";
      };
    };
  };

  # The plugin itself. Noctalia scans ~/.local/share/noctalia/plugins as its
  # "local" source, so linking the tree there installs it without the shell's
  # plugin browser (which would need to write to config.toml — a read-only
  # store symlink here). Pinned by the noctalia-plugins flake input.
  xdg.dataFile."noctalia/plugins/ai-usagebar".source =
    "${inputs.noctalia-plugins}/ai-usagebar";

  # Autostart Steam minimised to the tray (Valve's -silent flag).
  xdg.configFile."autostart/steam.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Steam
    Comment=Start Steam minimised to the system tray
    Exec=steam -silent
    Icon=steam
    Terminal=false
    Categories=Game;
  '';

  # Hyprland — hand-written Lua config + Noctalia colour template ---------
  xdg.configFile."hypr/hyprland.lua".source = ./hypr/hyprland.lua;
  xdg.configFile."noctalia/templates/hyprland.lua".source = ./noctalia/templates/hyprland.lua;
}
