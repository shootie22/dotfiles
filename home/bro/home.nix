{ config, pkgs, unstable ? pkgs, ... }:

let
  dotfilesRoot = "/home/bro/gitrepos/github/dotfiles";
  broHome = "${dotfilesRoot}/home/bro";
  screengrabScripts = "${broHome}/scripts/screengrab";
  mediaScripts = "${broHome}/scripts/media";
in
{
  home.stateVersion = "25.11";

  nixpkgs.config.allowUnfree = true;

  home.packages = with pkgs; [

    # general
    meli
    unstable.iamb
    bitwarden-cli
    file
    mpv
    swayimg
    vlc
    zellij
    wiremix
    parsec-bin
    thunar
    mousepad
    kdePackages.ark
    kdePackages.dolphin
    kdePackages.filelight
    kdePackages.gwenview
    # Dolphin embeds Konsole's KPart as its F4 terminal panel, and KIO hands
    # Terminal=true .desktop entries to Konsole too, so text files associated
    # with a console editor actually open somewhere.
    kdePackages.konsole
    # keditfiletype, which is what Dolphin's Properties -> File type -> "Change"
    # button shells out to, plus kioclient for testing associations from a shell.
    kdePackages.kde-cli-tools
    # kbuildsycoca6, to rebuild the service cache by hand after changing
    # associations instead of waiting for an application to notice.
    kdePackages.kservice
    filezilla

    # utilities
    calcurse
    tealdeer
    helix
    unstable.claude-code
    opencode

    # development
    gh
    godot
    #antigravity

    # Games
    runelite

    (writeShellScriptBin "record-region" ''
      exec "${screengrabScripts}/record-region" "$@"
    '')
    (writeShellScriptBin "preview" ''
      exec "${mediaScripts}/preview" "$@"
    '')
  ];

  home.pointerCursor = {
    package = pkgs.hackneyed;
    name = "Hackneyed";
    size = 24;

    gtk.enable = true;
    x11.enable = true;
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "video/mp4" = "vlc.desktop";
      "video/x-matroska" = "vlc.desktop";
      "video/webm" = "vlc.desktop";
      "video/quicktime" = "vlc.desktop";
      "video/x-msvideo" = "vlc.desktop";
      "video/mpeg" = "vlc.desktop";
      "video/ogg" = "vlc.desktop";
      "video/3gpp" = "vlc.desktop";
      "video/x-flv" = "vlc.desktop";
      "video/x-ms-wmv" = "vlc.desktop";
      "image/jpeg" = "org.kde.gwenview.desktop";
      "image/png" = "org.kde.gwenview.desktop";
      "image/gif" = "org.kde.gwenview.desktop";
      "image/bmp" = "org.kde.gwenview.desktop";
      "image/webp" = "org.kde.gwenview.desktop";
      "image/tiff" = "org.kde.gwenview.desktop";
      "image/avif" = "org.kde.gwenview.desktop";
      "image/heif" = "org.kde.gwenview.desktop";
      "image/svg+xml" = "org.kde.gwenview.desktop";

      "audio/mpeg" = "vlc.desktop";
      "audio/mp4" = "vlc.desktop";
      "audio/flac" = "vlc.desktop";
      "audio/ogg" = "vlc.desktop";
      "audio/x-vorbis+ogg" = "vlc.desktop";
      "audio/x-opus+ogg" = "vlc.desktop";
      "audio/vnd.wave" = "vlc.desktop";
      "audio/aac" = "vlc.desktop";
      "audio/x-ms-wma" = "vlc.desktop";
      "audio/x-matroska" = "vlc.desktop";
      "application/ogg" = "vlc.desktop";

      # Mousepad rather than Helix: Helix is Terminal=true, so double-clicking a
      # file in Dolphin would spawn a modal terminal editor. Helix is still one
      # click away under "Open With", and now has Konsole to open into.
      "text/plain" = "org.xfce.mousepad.desktop";
      "text/markdown" = "org.xfce.mousepad.desktop";
      "text/csv" = "org.xfce.mousepad.desktop";
      "text/x-log" = "org.xfce.mousepad.desktop";
      "text/x-patch" = "org.xfce.mousepad.desktop";
      "text/x-makefile" = "org.xfce.mousepad.desktop";
      "text/x-python" = "org.xfce.mousepad.desktop";
      "text/x-lua" = "org.xfce.mousepad.desktop";
      "text/x-go" = "org.xfce.mousepad.desktop";
      "text/x-java" = "org.xfce.mousepad.desktop";
      "text/x-csrc" = "org.xfce.mousepad.desktop";
      "text/x-chdr" = "org.xfce.mousepad.desktop";
      "text/x-c++src" = "org.xfce.mousepad.desktop";
      "text/x-c++hdr" = "org.xfce.mousepad.desktop";
      "text/rust" = "org.xfce.mousepad.desktop";
      "application/json" = "org.xfce.mousepad.desktop";
      "application/yaml" = "org.xfce.mousepad.desktop";
      "application/toml" = "org.xfce.mousepad.desktop";
      "application/xml" = "org.xfce.mousepad.desktop";
      "application/x-shellscript" = "org.xfce.mousepad.desktop";

      "inode/directory" = "org.kde.dolphin.desktop";

      "text/html" = "librewolf.desktop";
      "application/xhtml+xml" = "librewolf.desktop";
      "x-scheme-handler/http" = "librewolf.desktop";
      "x-scheme-handler/https" = "librewolf.desktop";

      "application/x-deb" = "org.kde.ark.desktop";
      "application/x-cd-image" = "org.kde.ark.desktop";
      "application/x-bcpio" = "org.kde.ark.desktop";
      "application/x-cpio" = "org.kde.ark.desktop";
      "application/x-cpio-compressed" = "org.kde.ark.desktop";
      "application/x-sv4cpio" = "org.kde.ark.desktop";
      "application/x-sv4crc" = "org.kde.ark.desktop";
      "application/x-rpm" = "org.kde.ark.desktop";
      "application/x-compress" = "org.kde.ark.desktop";
      "application/gzip" = "org.kde.ark.desktop";
      "application/x-bzip" = "org.kde.ark.desktop";
      "application/x-bzip2" = "org.kde.ark.desktop";
      "application/x-lzma" = "org.kde.ark.desktop";
      "application/x-xz" = "org.kde.ark.desktop";
      "application/zlib" = "org.kde.ark.desktop";
      "application/zstd" = "org.kde.ark.desktop";
      "application/x-lz4" = "org.kde.ark.desktop";
      "application/x-lzip" = "org.kde.ark.desktop";
      "application/x-lrzip" = "org.kde.ark.desktop";
      "application/x-lzop" = "org.kde.ark.desktop";
      "application/x-source-rpm" = "org.kde.ark.desktop";
      "application/vnd.debian.binary-package" = "org.kde.ark.desktop";
      "application/vnd.efi.iso" = "org.kde.ark.desktop";
      "application/vnd.ms-cab-compressed" = "org.kde.ark.desktop";
      "application/x-xar" = "org.kde.ark.desktop";
      "application/x-iso9660-appimage" = "org.kde.ark.desktop";
      "application/x-archive" = "org.kde.ark.desktop";
      "application/x-tar" = "org.kde.ark.desktop";
      "application/x-compressed-tar" = "org.kde.ark.desktop";
      "application/x-bzip-compressed-tar" = "org.kde.ark.desktop";
      "application/x-bzip2-compressed-tar" = "org.kde.ark.desktop";
      "application/x-tarz" = "org.kde.ark.desktop";
      "application/x-xz-compressed-tar" = "org.kde.ark.desktop";
      "application/x-lzma-compressed-tar" = "org.kde.ark.desktop";
      "application/x-lzip-compressed-tar" = "org.kde.ark.desktop";
      "application/x-tzo" = "org.kde.ark.desktop";
      "application/x-lrzip-compressed-tar" = "org.kde.ark.desktop";
      "application/x-lz4-compressed-tar" = "org.kde.ark.desktop";
      "application/x-zstd-compressed-tar" = "org.kde.ark.desktop";
      "application/x-7z-compressed" = "org.kde.ark.desktop";
      "application/vnd.rar" = "org.kde.ark.desktop";
      "application/zip" = "org.kde.ark.desktop";
      "application/x-java-archive" = "org.kde.ark.desktop";
      "application/x-lha" = "org.kde.ark.desktop";
      "application/x-stuffit" = "org.kde.ark.desktop";
      "application/x-arj" = "org.kde.ark.desktop";
      "application/arj" = "org.kde.ark.desktop";

      "x-scheme-handler/discord-409416265891971072" = "discord-409416265891971072.desktop";
      "x-scheme-handler/claude-cli" = "claude-code-url-handler.desktop";
      "x-scheme-handler/discord-455712169795780630" = "discord-455712169795780630.desktop";
      "x-scheme-handler/discord-1216669957799018608" = "discord-1216669957799018608.desktop";
    };
  };

  xdg.configFile = {
    "mimeapps.list".force = true;
    "hypr/hyprland.conf".source = ./hypr/hyprland.conf;
    "hypr/look.conf".source = ./hypr/look.conf;
    "hypr/input.conf".source = ./hypr/input.conf;
    "hypr/keybinds.conf".source = ./hypr/keybinds.conf;
    "hypr/windowrules.conf".source = ./hypr/windowrules.conf;
    "iamb/config.toml".source = ./iamb/config.toml;
    "kitty/kitty.conf".source = ./kitty/kitty.conf;
    "meli/config.toml" = {
      source = ./meli/config.toml;
      force = true;
    };
  };

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
