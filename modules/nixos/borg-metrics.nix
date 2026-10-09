# When each Borg job last made an archive, and the paths it covers, for
# node-exporter's textfile collector: Hub's backups view (infra-hub #16)
# shows from these which archive holds a service's folder and how old it is.
#
# dotfiles.borgMetrics.jobs = [ "thinkcentre" ]; names jobs from
# services.borgbackup.jobs. Written after a successful `borg create` only, so
# a failed run leaves the last good time in place.
{ config, lib, ... }:

let
  cfg = config.dotfiles.borgMetrics;
  textfileDir = "/var/lib/node-exporter-textfile";
  jobs = config.services.borgbackup.jobs;
in
{
  options.dotfiles.borgMetrics.jobs = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Borg jobs that report their last archive time and paths.";
  };

  config.services.borgbackup.jobs = lib.genAttrs cfg.jobs (name: {
    readWritePaths = [ textfileDir ];
    postCreate = ''
      tmp=$(mktemp ${textfileDir}/.borg_${name}.XXXXXX)
      cat >"$tmp" <<EOF
      # HELP borg_last_archive_timestamp_seconds When this Borg job last created an archive.
      # TYPE borg_last_archive_timestamp_seconds gauge
      borg_last_archive_timestamp_seconds{job="${name}",archive="$archiveName"} $(date +%s)
      # HELP borg_job_path A path this Borg job archives.
      # TYPE borg_job_path gauge
      ${lib.concatMapStringsSep "\n" (p: ''borg_job_path{job="${name}",path="${p}"} 1'') jobs.${name}.paths}
      EOF
      chmod 0644 "$tmp"
      mv "$tmp" ${textfileDir}/borg_${name}.prom
    '';
  });
}
