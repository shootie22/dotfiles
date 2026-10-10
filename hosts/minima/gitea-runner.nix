# Gitea Actions runner for macOS builds (runs-on: macos-arm64).
#
# Host mode: jobs run straight on the Mac (no docker on macOS) as the
# unprivileged _gitea-runner user, which has no sudo and can't write to
# Homebrew. Jobs bring their toolchain through nix or setup-* actions.
#
# Since the Mac also keeps everyone's backups and runs minima, each job is
# fenced in:
# - One job per registration. A root loop registers an ephemeral runner, the
#   runner takes one job (Gitea revokes its credentials as soon as the job is
#   assigned) and exits; then the loop kills the user's leftover processes and
#   wipes its home and temp files, so nothing carries over to the next job.
#   The registration token is root's only.
# - sandbox-exec: no reads or writes in /Users, /Volumes (the backups) or the
#   loop's own folder; writes only in the job user's home and temp folders.
# - pf: the job user can't open connections to private, LAN, tailnet or
#   link-local addresses, only the public internet (Gitea included) and the
#   runner's own cache on localhost.
# - Background QoS (taskpolicy -b): builds get the leftover CPU and I/O, so
#   they don't slow the minima VM down.
#
# Which repos it serves depends on the token: one from radu's Settings >
# Actions > Runners keeps it to radu's repos; one from Site Administration >
# Actions > Runners opens it to every repo. Set it with
# `sudo gitea-runner-set-token`; the loop waits until there is one.
{ lib, pkgs, ... }:

let
  user = "_gitea-runner";
  uid = 450;
  home = "/var/lib/gitea-runner";
  ctl = "/var/lib/gitea-runner-ctl";
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
    # Jobs reach the cache on localhost, the one local address pf lets them use.
    cache = {
      enabled = true;
      dir = "${home}/cache";
      host = "127.0.0.1";
      port = 8088;
    };
    host.workdir_parent = "${home}/work";
  };

  runner = lib.getExe' pkgs.gitea-actions-runner "gitea-runner";

  # Allow by default (Xcode and friends touch a lot of the system), then take
  # away what a job has no business with. Later rules win.
  sandbox = pkgs.writeText "gitea-runner.sb" ''
    (version 1)
    (allow default)
    (deny file-write*
      (subpath "/"))
    (allow file-write*
      (subpath "/private${home}")
      (subpath "/private/tmp")
      (subpath "/private/var/tmp")
      (subpath "/private/var/folders")
      (literal "/dev/null")
      (literal "/dev/zero")
      (literal "/dev/tty")
      (regex #"^/dev/fd/"))
    (deny file-read* file-write*
      (subpath "/Users")
      (subpath "/Volumes")
      (subpath "/private/var/root")
      (subpath "/private${ctl}")
      (subpath "/Library/Keychains")
      (subpath "/private/var/db/dslocal"))
    (deny process-exec
      (literal "/usr/bin/sudo")
      (literal "/usr/bin/su")
      (literal "/usr/bin/crontab")
      (literal "/usr/bin/at")
      (literal "/bin/launchctl"))
  '';

  pfRules = pkgs.writeText "gitea-runner.pf" ''
    table <ci_private> const { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 127.0.0.0/8, 224.0.0.0/4, ::1, fc00::/7, fe80::/10, ff00::/8 }
    pass out quick on lo0 proto tcp from any to 127.0.0.1 port 8088 user ${user}
    block return out quick proto { tcp, udp } from any to <ci_private> user ${user}
  '';

  loop = pkgs.writeShellScript "gitea-runner-loop" ''
    set -u
    clean() {
      pkill -9 -u ${user} 2>/dev/null
      sleep 1
      rm -rf ${home}
      install -d -m 0700 -o ${user} -g ${user} ${home}
      find /private/tmp /private/var/tmp /private/var/folders -mindepth 1 -user ${user} -delete 2>/dev/null
    }
    while true; do
      if [ ! -s ${ctl}/token ]; then sleep 60; continue; fi
      clean
      cd ${home}
      if ! sudo -u ${user} -H ${runner} register --no-interactive --ephemeral \
          --config ${config} --instance https://git.radunenu.com \
          --token-file /dev/stdin --name minima-mac --labels macos-arm64:host < ${ctl}/token; then
        sleep 60; continue
      fi
      sudo -u ${user} -H --preserve-env=PATH /usr/sbin/taskpolicy -b \
        /usr/bin/sandbox-exec -f ${sandbox} ${runner} daemon --once --config ${config}
      sleep 5
    done
  '';

  setToken = pkgs.writeShellScriptBin "gitea-runner-set-token" ''
    set -eu
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
    read -rsp "Runner registration token: " token; echo
    umask 077
    printf '%s\n' "$token" > ${ctl}/token
    echo "Saved. The runner registers for its next job within a minute."
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
    install -d -m 0700 -o root -g wheel ${ctl}
    install -d -m 0700 -o ${user} -g ${user} ${home}
  '';

  environment.systemPackages = [ setToken ];

  # The loop runs as root (it registers and cleans up); jobs run as the user.
  launchd.daemons.gitea-runner.serviceConfig = {
    Label = label;
    ProgramArguments = [ "${loop}" ];
    RunAtLoad = true;
    KeepAlive = true;
    ThrottleInterval = 30;
    EnvironmentVariables = {
      # node for actions/checkout and other JS actions; nix for jobs that
      # build through a flake; Apple's clang and friends from /usr/bin.
      PATH = lib.makeBinPath [ pkgs.nodejs pkgs.git pkgs.git-lfs ]
        + ":/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    };
    StandardOutPath = "${ctl}/runner.log";
    StandardErrorPath = "${ctl}/runner.log";
  };

  # macOS's /etc/pf.conf loads every com.apple/* anchor; this adds one and
  # turns pf on (it's off by default, and the stock rules pass everything).
  launchd.daemons.gitea-runner-pf.serviceConfig = {
    Label = "org.nixos.gitea-runner-pf";
    ProgramArguments = [
      "/bin/sh"
      "-c"
      "/sbin/pfctl -a com.apple/250.gitea-runner -f ${pfRules} && /sbin/pfctl -E"
    ];
    RunAtLoad = true;
    StandardOutPath = "${ctl}/pf.log";
    StandardErrorPath = "${ctl}/pf.log";
  };
}
