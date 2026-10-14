# Daily Borg backup of the whole Minima VM disk image to the Expansion drive
# (which Backblaze then copies off-site).
#
# The live image is never read directly: the guest flushes its writes, then an
# APFS clone (instant, copy-on-write) gives a crash-consistent point-in-time
# copy. Restore: extract the image and copy it to ~/.lima/minima/disk with
# the VM stopped (`minima-vm stop`).
#
# Repo: /Volumes/Expansion/borg_repos/minima-vm (repokey-blake2), passphrase
# in ~/.config/borg/minima-vm.passphrase; keep a copy of it off this Mac.
#
# macOS doesn't let a launchd job write to an external drive, but it does let
# sshd's sessions (as the other Macs' and servers' backups arrive). So the job
# goes through ssh to this Mac itself: the drive is written by `borg serve`
# under sshd. Its key is made here on activation and never leaves the Mac;
# authorized_keys lets it only run borg serve on this one repo, from this Mac.
{ pkgs, ... }:

let
  user = "radu";
  home = "/Users/${user}";
  borg = "/opt/homebrew/bin/borg";
  limactl = "/opt/homebrew/bin/limactl";
  repo = "/Volumes/Expansion/borg_repos/minima-vm";
  key = "${home}/.ssh/minima-vm-backup";

  backup = pkgs.writeShellScript "minima-vm-backup" ''
    set -euo pipefail
    export BORG_REPO=ssh://${user}@localhost${repo}
    export BORG_RSH="ssh -i ${key} -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile=${key}.known_hosts -o StrictHostKeyChecking=yes"
    export BORG_PASSCOMMAND="cat ${home}/.config/borg/minima-vm.passphrase"
    vmdir=${home}/.lima/minima
    clone=$vmdir/disk.backup-clone

    log() { echo "$(date '+%F %T') $*"; }

    [ -d ${repo} ] || { log "backup drive not mounted: ${repo}"; exit 1; }

    rm -f "$clone"
    trap 'rm -f "$clone"' EXIT

    if [ "$(${limactl} list minima --format '{{.Status}}')" = Running ]; then
      ${limactl} shell --workdir / minima sync
    fi
    cp -c "$vmdir/disk" "$clone"
    log "cloned VM disk"

    ${borg} create --stats --compression zstd,3 \
      "::minima-vm-{now:%Y-%m-%dT%H:%M}" "$clone" "$vmdir/lima.yaml"
    ${borg} prune --stats --glob-archives 'minima-vm-*' \
      --keep-daily 7 --keep-weekly 4 --keep-monthly 6
    ${borg} compact
    log "done"
  '';
in
{
  launchd.daemons.minima-vm-backup = {
    command = "${backup}";
    serviceConfig = {
      Label = "org.nixos.minima-vm-backup";
      UserName = user;
      GroupName = "staff";
      EnvironmentVariables.HOME = home;
      # After Fuji's (03:30) and before thinkcentre's (05:00 CEST) jobs.
      StartCalendarInterval = [ { Hour = 4; Minute = 15; } ];
      StandardOutPath = "${home}/Library/Logs/minima-vm-backup.log";
      StandardErrorPath = "${home}/Library/Logs/minima-vm-backup.log";
    };
  };

  # Borg targets on the USB Expansion drive must be mounted even when nobody
  # has logged in (e.g. after a reboot unlocked over SSH).
  system.activationScripts.postActivation.text = ''
    defaults write /Library/Preferences/SystemConfiguration/autodiskmount \
      AutomountDisksWithoutUserLogin -bool true

    # The backup's ssh key and what it may do: borg serve on its repo, only
    # from this Mac, nothing else (no shell, forwarding or pty). Other lines in
    # authorized_keys stay; this one is rewritten each time.
    install -d -m 0700 -o ${user} -g staff ${home}/.ssh
    if [ ! -s ${key} ]; then
      sudo -u ${user} ssh-keygen -q -t ed25519 -N "" -C minima-vm-backup -f ${key}
    fi
    ak=${home}/.ssh/authorized_keys
    touch "$ak"
    { grep -v ' minima-vm-backup$' "$ak" || true
      echo "restrict,from=\"127.0.0.1,::1\",command=\"${borg} serve --restrict-to-repository ${repo}\" $(cat ${key}.pub)"
    } > "$ak.new"
    install -m 0600 -o ${user} -g staff "$ak.new" "$ak"
    rm -f "$ak.new"
    # Pinned to this Mac's own host key, so nothing else can pose as it.
    echo "localhost $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" > ${key}.known_hosts
    chown ${user}:staff ${key}.known_hosts
  '';
}
