# Copies service folders to the other site over Nebula every few minutes, so
# a standby there can take over when a site is gone (infrastructure #142,
# decision 2026-10-06: plain rsync, at worst the last copy's worth of writes
# is lost).
#
# send.<job>:  this host pushes `source` to `to`, where it lands in
#              <receive.dir>/<this host>/<job>. SQLite files listed in
#              `sqlite` are copied from a snapshot (sqlite3 .backup), never
#              mid-write.
# receive:     this host takes copies from the hosts in `from`. They log in as
#              `standby`, from their mesh address only, and can't do anything
#              but write into their own folder (rrsync, through one sudo rule
#              so owners and modes survive).
#
# Every job leaves standby_copy_last_success_timestamp_seconds for
# node-exporter's textfile collector; Prometheus alerts when it gets old.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.standbyCopy;
  mesh = import ../../lib/nebula.nix;
  keys = cfg.publicKeys;
  stateDir = "/var/lib/standby-copy";
  textfileDir = "/var/lib/node-exporter-textfile";

  receiveScript = pkgs.writeShellScript "standby-receive" ''
    set -eu
    sender="$1"
    ${lib.optionalString (cfg.receive.requireMount != null) ''
      # Never fill the root filesystem when the standby disk isn't there.
      ${pkgs.util-linux}/bin/mountpoint -q ${cfg.receive.requireMount} || {
        echo "${cfg.receive.requireMount} is not mounted" >&2; exit 1; }
    ''}
    install -d -m 0700 ${cfg.receive.dir} ${cfg.receive.dir}/"$sender"
    # -no-lock: several jobs from one sender run at once, each into its own
    # folder.
    exec ${pkgs.rrsync}/bin/rrsync -wo -no-lock ${cfg.receive.dir}/"$sender"
  '';

  sendJob = name: job:
    let
      target = "standby@${mesh.hosts.${job.to}.ip}";
      excludes = [ "/.standby-copy-ok" ]
        ++ lib.concatMap (p: [ "/${p}" "/${p}-wal" "/${p}-shm" "/${p}-journal" ]) job.sqlite ++ job.exclude;
      rsyncArgs = [ "-aH" "--numeric-ids" "--delete" "--partial" ]
        ++ lib.optional (job.bwlimit != null) "--bwlimit=${job.bwlimit}";
    in {
      description = "Copy ${name} to ${job.to} (standby)";
      # Never restarted by a switch: a first copy can run for hours, and the
      # switch (and comin behind it) would wait for it. The next run picks up
      # the change.
      restartIfChanged = false;
      after =[ "network-online.target" "nebula@mesh.service" ];
      wants = [ "network-online.target" ];
      path = with pkgs; [ rsync openssh sqlite coreutils findutils ];
      serviceConfig = {
        Type = "oneshot";
        Nice = 10;
        IOSchedulingClass = "idle";
        TimeoutStartSec = "12h"; # the first copy of a big folder; --partial resumes after
      };
      script = ''
        set -euo pipefail
        ${lib.optionalString (job.onlyWhenActive != null) ''
          # Only the node running the service sends (site-failover.nix). A node
          # that can't ask the cluster fails here, so the stale alert still
          # works; one that isn't active steps aside and drops its metric.
          active=$(${config.services.k3s.package}/bin/k3s kubectl get node ${config.networking.hostName} \
            -o jsonpath='{.metadata.labels.ha\.radunenu\.com/${job.onlyWhenActive}}')
          if [ "$active" != active ]; then
            echo "not the active node for ${job.onlyWhenActive}, nothing to send"
            rm -f ${textfileDir}/standby_copy_${name}.prom
            exit 0
          fi
        ''}
        # source may be a glob (a local-path volume's folder has a generated
        # name); it has to match exactly one folder.
        shopt -s nullglob
        matches=( ${job.source} )
        if [ ''${#matches[@]} -ne 1 ] || [ ! -d "''${matches[0]}" ]; then
          echo "${job.source} matches ''${#matches[@]} folders, not exactly one" >&2
          exit 1
        fi
        src=''${matches[0]}
        ssh="ssh -i ${config.sops.secrets.standby_copy_key.path} -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${stateDir}/known_hosts"
        start=$(date +%s)

        snap=$(mktemp -d ${stateDir}/snap.XXXXXX)
        ${if job.postCopy == null then ''
          trap 'rm -rf "$snap"' EXIT
        '' else ''
          # Undone whatever happens to the copy (e.g. a game's saves resumed).
          trap 'rm -rf "$snap"; ${pkgs.writeShellScript "standby-copy-${name}-post" job.postCopy} || echo "post-copy step failed" >&2' EXIT
        ''}
        ${lib.optionalString (job.preCopy != null) ''
          # Getting the folder into a state worth copying (e.g. a game saving
          # its world and pausing saves). A failure here doesn't stop the copy.
          ${pkgs.writeShellScript "standby-copy-${name}-pre" job.preCopy} || echo "pre-copy step failed, copying anyway" >&2
        ''}
        ${lib.concatMapStrings (db: ''
          mkdir -p "$snap/$(dirname ${lib.escapeShellArg db})"
          # sqlite3 would quietly create an empty database at a wrong path.
          test -f "$src/"${lib.escapeShellArg db}
          # Waits up to a minute for the app to let go of a write lock.
          sqlite3 -cmd '.timeout 60000' "$src/"${lib.escapeShellArg db} ".backup '$snap/${db}'"
          chown --reference="$src/"${lib.escapeShellArg db} "$snap/"${lib.escapeShellArg db}
          chmod --reference="$src/"${lib.escapeShellArg db} "$snap/"${lib.escapeShellArg db}
        '') job.sqlite}

        # 24: files vanished while copying, normal for live folders.
        rc=0
        rsync ${lib.escapeShellArgs rsyncArgs} -e "$ssh" \
          ${lib.concatMapStringsSep " " (e: "--exclude=${lib.escapeShellArg e}") excludes} \
          "$src/" ${target}:${name}/ || rc=$?
        [ $rc -eq 0 ] || [ $rc -eq 24 ] || exit $rc
        # The SQLite snapshots, and a marker saying a whole copy made it: a
        # standby only takes over a folder that has one (site-failover.nix).
        # Only the files: the temporary folders' owners and modes must not land
        # on the copy's folders.
        date +%s > "$snap/.standby-copy-ok"
        (cd "$snap" && find . -type f -printf '%P\n') |
          rsync -aH --numeric-ids --no-implied-dirs --files-from=- -e "$ssh" "$snap/" ${target}:${name}/

        end=$(date +%s)
        tmp=$(mktemp ${textfileDir}/.standby_copy_${name}.XXXXXX)
        cat >"$tmp" <<EOF
        # HELP standby_copy_last_success_timestamp_seconds When the last copy to the standby finished.
        # TYPE standby_copy_last_success_timestamp_seconds gauge
        standby_copy_last_success_timestamp_seconds{copy="${name}",to="${job.to}"} $end
        # HELP standby_copy_duration_seconds How long the last copy took.
        # TYPE standby_copy_duration_seconds gauge
        standby_copy_duration_seconds{copy="${name}",to="${job.to}"} $((end - start))
        EOF
        chmod 0644 "$tmp"
        mv "$tmp" ${textfileDir}/standby_copy_${name}.prom
      '';
    };
in
{
  options.dotfiles.standbyCopy = {
    keyFile = lib.mkOption {
      type = lib.types.path;
      default = ../../secrets + "/${config.networking.hostName}-standby-copy.yaml";
      description = "sops file holding this host's standby_copy_key.";
    };
    publicKeys = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = import ../../lib/standby-copy.nix;
      description = "Each sending host's public key (lib/standby-copy.nix).";
    };
    send = lib.mkOption {
      default = { };
      description = "Folders this host copies to a standby in the other site.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          source = lib.mkOption { type = lib.types.str; };
          to = lib.mkOption { type = lib.types.enum (lib.attrNames mesh.hosts); };
          interval = lib.mkOption { type = lib.types.str; default = "*:0/10"; };
          sqlite = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "SQLite databases (relative to source) to copy from a snapshot.";
          };
          exclude = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          bwlimit = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "rsync --bwlimit, e.g. \"20m\".";
          };
          preCopy = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Shell run before the copy; its failure doesn't stop the copy.";
          };
          postCopy = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Shell run after the copy, whatever happened to it.";
          };
          onlyWhenActive = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Send only while this node holds the service's active label (site-failover.nix).";
          };
        };
      });
    };
    receive = {
      enable = lib.mkEnableOption "taking standby copies from other hosts";
      dir = lib.mkOption { type = lib.types.str; };
      from = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      requireMount = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Refuse copies unless this is mounted.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.send != { } || cfg.receive.enable) {
      systemd.tmpfiles.rules = [ "d ${textfileDir} 0755 root root -" ];
    })

    (lib.mkIf (cfg.send != { }) {
      sops.secrets.standby_copy_key = {
        sopsFile = cfg.keyFile;
        owner = "root";
        mode = "0400";
      };
      systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];
      systemd.services = lib.mapAttrs' (name: job:
        lib.nameValuePair "standby-copy-${name}" (sendJob name job)) cfg.send;
      systemd.timers = lib.mapAttrs' (name: job:
        lib.nameValuePair "standby-copy-${name}" {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = job.interval;
            RandomizedDelaySec = 60;
            Persistent = false;
          };
        }) cfg.send;
    })

    (lib.mkIf cfg.receive.enable {
      users.groups.standby = { };
      users.users.standby = {
        isSystemUser = true;
        group = "standby";
        shell = pkgs.bashInteractive;
        openssh.authorizedKeys.keys = map (s:
          ''from="${mesh.hosts.${s}.ip}",restrict,command="/run/wrappers/bin/sudo -n ${receiveScript} ${s}" ${keys.${s}}'')
          cfg.receive.from;
      };
      security.sudo.extraRules = [{
        users = [ "standby" ];
        commands = map (s: { command = "${receiveScript} ${s}"; options = [ "NOPASSWD" ]; }) cfg.receive.from;
      }];
      # rrsync reads the requested rsync command from here.
      security.sudo.extraConfig = ''
        Defaults:standby env_keep += "SSH_ORIGINAL_COMMAND"
      '';
      services.openssh.settings.AllowUsers = [ "standby" ];
      # Only over the mesh.
      networking.firewall.interfaces."nebula.mesh".allowedTCPPorts = [ 22 ];
    })
  ];
}
