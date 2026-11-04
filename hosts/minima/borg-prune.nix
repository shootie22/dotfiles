# Thinning out fuji's and the thinkcentre's Borg repositories, here on the Mac
# that holds them (infrastructure security audit, 2026-11-03). The servers
# used to prune their own archives, so whoever took over one could delete its
# backups too. Their keys may now only append (`borg serve --append-only` in
# borgworker's authorized_keys), and this job, with direct access to the
# drive, keeps the same history they kept: 7 daily, 4 weekly, 6 monthly (and
# 1 yearly for the thinkcentre).
#
# Needs each repository's passphrase in ~radu/.config/borg/<repo>.passphrase
# (mode 600, as for minima-vm). A repository without one is skipped and
# logged, so nothing is pruned before that's set up.
{ pkgs, ... }:

let
  user = "radu";
  home = "/Users/${user}";
  borg = "/opt/homebrew/bin/borg";
  repos = "/Volumes/Expansion/borg_repos";

  prune = pkgs.writeShellScript "borg-prune-servers" ''
    set -uo pipefail
    log() { echo "$(date '+%F %T') $*"; }
    status=0

    # repository, archive prefix, keep flags
    run() {
      repo=$1 glob=$2; shift 2
      pass=${home}/.config/borg/$repo.passphrase
      if [ ! -d "${repos}/$repo" ]; then log "$repo: drive not mounted"; status=1; return; fi
      if [ ! -s "$pass" ]; then log "$repo: no passphrase in $pass, skipped"; return; fi
      export BORG_REPO="${repos}/$repo" BORG_PASSCOMMAND="cat $pass"
      # A server's backup may still be writing; wait for its lock.
      if ${borg} prune --lock-wait 3600 --stats --glob-archives "$glob" "$@" \
         && ${borg} compact --lock-wait 3600; then
        log "$repo: pruned"
      else
        log "$repo: prune failed"; status=1
      fi
    }

    run fuji-k3s 'FUJI---K3s-*' --keep-daily 7 --keep-weekly 4 --keep-monthly 6
    run server-backups 'THINKCENTRE---Weekly-backup-*' --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --keep-yearly 1
    exit $status
  '';
in
{
  launchd.daemons.borg-prune-servers = {
    command = "${prune}";
    serviceConfig = {
      Label = "org.nixos.borg-prune-servers";
      UserName = user;
      GroupName = "staff";
      EnvironmentVariables.HOME = home;
      # After the servers' backups (fuji 03:30, the thinkcentre 03:00 UTC)
      # and the Mac's own (04:15).
      StartCalendarInterval = [ { Hour = 7; Minute = 30; } ];
      StandardOutPath = "${home}/Library/Logs/borg-prune-servers.log";
      StandardErrorPath = "${home}/Library/Logs/borg-prune-servers.log";
    };
  };
}
