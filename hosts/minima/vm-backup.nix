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
{ pkgs, ... }:

let
  user = "radu";
  home = "/Users/${user}";
  borg = "/opt/homebrew/bin/borg";
  limactl = "/opt/homebrew/bin/limactl";

  backup = pkgs.writeShellScript "minima-vm-backup" ''
    set -euo pipefail
    export BORG_REPO=/Volumes/Expansion/borg_repos/minima-vm
    export BORG_PASSCOMMAND="cat ${home}/.config/borg/minima-vm.passphrase"
    vmdir=${home}/.lima/minima
    clone=$vmdir/disk.backup-clone

    log() { echo "$(date '+%F %T') $*"; }

    [ -d "$BORG_REPO" ] || { log "backup drive not mounted: $BORG_REPO"; exit 1; }

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
  '';
}
