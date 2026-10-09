# Gitea Actions runner for macOS builds (runs-on: macos-arm64).
#
# Host mode: macOS has no docker, so jobs run straight on the Mac as the
# unprivileged _gitea-runner user. That user has no sudo and can't write to
# Homebrew; jobs bring their toolchain through nix (`nix develop`, `nix build`)
# or setup-* actions, which install into the runner's home.
#
# The runner is registered to radu's repos only, not the whole instance. It
# stays off until the one-time registration below writes .runner.
#
#   Get a token: git.radunenu.com > radu's Settings > Actions > Runners
#   On the Mac:
#     sudo -u _gitea-runner -H sh -c 'cd /var/lib/gitea-runner && act_runner register \
#       --no-interactive --instance https://git.radunenu.com --token <token> \
#       --name macminim4 --labels macos-arm64:host'
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

  # For the one-time register command.
  environment.systemPackages = [ pkgs.gitea-actions-runner ];

  launchd.daemons.gitea-runner.command =
    "${pkgs.gitea-actions-runner}/bin/act_runner daemon --config ${config}";
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
