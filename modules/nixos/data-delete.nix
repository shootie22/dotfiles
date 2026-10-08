# Deleting a removed service's files (infrastructure #190). Hub removes a
# service first and keeps its data; deleting the data is a separate step,
# confirmed by typing the service's name, that opens a PR adding its folders
# here. A oneshot deletes each one that still exists. Only folders under the
# places services keep data, never one a site-failover service still uses:
# a mistake makes evaluation fail, so the PR's checks go red.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.dataDeletions;
  roots = [ "/home/main/services/" "/home/main/storage/" "/home/fuji/services/" "/home/standby/" "/srv/standby/" ];
  inUse = lib.mapAttrsToList (_: s: s.data or "") (config.dotfiles.siteFailover.services or { });
  ok = p:
    lib.any (r: lib.hasPrefix r p && p != r && lib.removePrefix r p != "") roots
    && !(lib.hasInfix "*" p) && !(lib.hasInfix ".." p)
    && !(lib.elem p inUse) && !(lib.any (d: d != "" && lib.hasPrefix (p + "/") d) inUse);
in
{
  options.dotfiles.dataDeletions = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Folders of removed services to delete on this host.";
  };

  config = lib.mkIf (cfg != [ ]) {
    assertions = map (p: {
      assertion = ok p;
      message = "dotfiles.dataDeletions: ${p} isn't a removed service's data folder (under ${lib.concatStringsSep ", " roots}, not in use by site-failover)";
    }) cfg;

    systemd.services.data-delete = {
      description = "Delete removed services' data";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = lib.concatMapStrings (p: ''
        if [ -e ${lib.escapeShellArg p} ]; then
          ${pkgs.coreutils}/bin/rm -rf --one-file-system -- ${lib.escapeShellArg p}
          echo "deleted ${p}"
        fi
      '') cfg;
    };
  };
}
