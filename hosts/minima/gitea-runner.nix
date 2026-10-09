# Gitea Actions runner for macOS builds (runs-on: macos-arm64).
#
# Host mode: macOS has no docker, so jobs run straight on the Mac as the
# unprivileged _gitea-runner user. That user has no sudo and can't write to
# Homebrew; jobs bring their toolchain through nix (`nix develop`, `nix build`)
# or setup-* actions, which install into the runner's home.
#
# The runner is registered to radu's repos only, not the whole instance. It
# stays off until `sudo gitea-runner-register` writes .runner; that asks for
# a token from git.radunenu.com > radu's Settings > Actions > Runners.
{ lib, pkgs, ... }:

let
  user = "_gitea-runner";
  uid = 450;
  home = "/var/lib/gitea-runner";
  label = "org.nixos.gitea-runner";

  config = (pkgs.formats.yaml { }).generate "gitea-runner.yaml" {
    log.level = "info";
    runner = {
      file = "${home}/.runner";
      # The Mac also runs the minima VM (8 of its 16 GB); one job at a time.
      capacity = 1;
      timeout = "3h";
      labels = [ "macos-arm64:host" ];
    };
    cache = {
      enabled = true;
      dir = "${home}/cache";
    };
    host.workdir_parent = "${home}/work";
  };

  runner = lib.getExe' pkgs.gitea-actions-runner "gitea-runner";

  register = pkgs.writeShellScriptBin "gitea-runner-register" ''
    set -eu
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
    read -rsp "Runner token: " token; echo
    cd ${home}
    printf '%s' "$token" | sudo -u ${user} -H ${runner} register --no-interactive \
      --config ${config} --instance https://git.radunenu.com \
      --token-file /dev/stdin --name macminim4 --labels macos-arm64:host
  '';
in
{
  users.knownUsers = [ user ];
  users.knownGroups = [ user ];
  users.groups.${user}.gid = uid;
  users.users.${user} = {
    inherit uid home;
    gid = uid;
    shell = "/usr/bin/false";
    description = "Gitea Actions runner";
    isHidden = true;
  };

  system.activationScripts.postActivation.text = ''
    install -d -m 0700 -o ${user} -g ${user} ${home}
  '';

  environment.systemPackages = [ register ];

  launchd.daemons.gitea-runner.command = "${runner} daemon --config ${config}";
  launchd.daemons.gitea-runner.serviceConfig = {
    Label = label;
    UserName = user;
    GroupName = user;
    WorkingDirectory = home;
    EnvironmentVariables = {
      HOME = home;
      # node for actions/checkout and other JS actions; nix for jobs that
      # build through a flake; Apple's clang and friends from /usr/bin.
      PATH = lib.makeBinPath [ pkgs.nodejs pkgs.git pkgs.git-lfs ]
        + ":/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
    # Only runs once registration has written .runner.
    KeepAlive.PathState."${home}/.runner" = true;
    ThrottleInterval = 30;
    # Builds yield to the VM.
    Nice = 10;
    StandardOutPath = "${home}/runner.log";
    StandardErrorPath = "${home}/runner.log";
  };
}
