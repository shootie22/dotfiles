# Services with files that move to the other site when theirs is gone
# (infrastructure, decision 2026-10-06 "Services with files fail over by
# themselves"). Runs on both nodes of a pair, one per site.
#
# For each service:
# - /srv/ha/<service> is a bind of the service's folder on this node (`data`):
#   the live one where it runs, the standby copy on the other node. The
#   Deployment mounts /srv/ha/<service> and only runs on the node labelled
#   ha.radunenu.com/<service>=active. site-failover.py makes the binds, once
#   the folder exists.
# - The copy (standby-copy.nix) goes from whichever node is active to the
#   other, every 10 minutes, and lands straight in the other node's folder.
# - site-failover.py moves the label when the active node is gone, and
#   fences: /srv/ha/<service> only exists while this node may run it, so a
#   node cut off from the cluster stops the service by itself.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.siteFailover;
  copy = config.dotfiles.standbyCopy;
  mesh = import ../../../lib/nebula.nix;
  k3s = "${config.services.k3s.package}/bin/k3s";
  # Runs a command inside a service's running pod (for hold-still steps).
  inPod = ns: app: cmd: ''
    pod=$(${k3s} kubectl -n ${ns} get pod -l app=${app} \
      -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')
    if [ -z "$pod" ]; then echo "${app} isn't running"; exit 0; fi
    ${k3s} kubectl -n ${ns} exec "$pod" -- sh -c ${lib.escapeShellArg cmd}
  '';
  # ClickHouse, with the credentials its container already has.
  clickhouse = c: query: inPod c.namespace c.app
    ''clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "${query}"'';
  # A Minecraft server's world, written out and held still while it's
  # copied (RCON; the password is the server's own Kubernetes secret).
  rcon = m: commands: ''
    ip=$(${k3s} kubectl -n ${m.namespace} get pod -l app=${m.app} \
      -o jsonpath='{.items[?(@.status.phase=="Running")].status.podIP}')
    if [ -z "$ip" ]; then echo "${m.app} isn't running, nothing to save"; exit 0; fi
    MCRCON_PASS=$(${k3s} kubectl -n ${m.namespace} get secret ${m.secret} -o jsonpath='{.data.${m.key}}' | base64 -d)
    export MCRCON_PASS
    ${pkgs.mcrcon}/bin/mcrcon -H "$ip" -P 25575 ${commands}
  '';
  python = pkgs.python3;
  settings = {
    node = config.networking.hostName;
    k3s = [ "${config.services.k3s.package}/bin/k3s" ];
    inherit (cfg) port interval;
    # Read-only status: localhost, and the mesh for the game relay.
    listen = [ "127.0.0.1" mesh.hosts.${config.networking.hostName}.ip ];
    fail_after = cfg.failAfter;
    api_grace = cfg.apiGrace;
    services = lib.mapAttrs (svc: s: {
      inherit (s) peer initial data stateless;
      incoming = if !s.stateless && incoming svc != s.data then incoming svc else null;
    }) cfg.services;
  };
  configFile = pkgs.writeText "site-failover.json" (builtins.toJSON settings);
  # Where the peer's copies arrive on this node (standby-copy.nix's layout).
  incoming = svc: "${copy.receive.dir}/${cfg.services.${svc}.peer}/${svc}";
in
{
  options.dotfiles.siteFailover = {
    port = lib.mkOption { type = lib.types.port; default = 9112; };
    interval = lib.mkOption { type = lib.types.int; default = 5; };
    failAfter = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Seconds after the cluster marks the active node not Ready (itself about 50 s after it goes quiet) before taking over.";
    };
    apiGrace = lib.mkOption {
      type = lib.types.int;
      default = 45;
      description = "How long the active node keeps running a service without reaching the cluster. Longer than a k3s restart, shorter than the other side takes to take over (about 85 s).";
    };
    services = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          stateless = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Nothing on disk (a game server with no world): only the label moves, nothing is copied, mounted or fenced.";
          };
          data = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "The service's folder on this node. May be a pattern matching exactly one folder (a local-path volume).";
          };
          peer = lib.mkOption { type = lib.types.str; description = "The node in the other site."; };
          initial = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Where the service runs the first time (where the live data is today).";
          };
          sqlite = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          exclude = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          preCopy = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Shell run before each copy (standby-copy.nix), e.g. to hold a database still.";
          };
          postCopy = lib.mkOption {
            type = lib.types.nullOr lib.types.lines;
            default = null;
            description = "Shell run after each copy, whatever happened to it.";
          };
          clickhouse = lib.mkOption {
            default = null;
            description = "A ClickHouse server: merges stopped while its folder is copied, so the parts on disk hold still.";
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                namespace = lib.mkOption { type = lib.types.str; };
                app = lib.mkOption { type = lib.types.str; description = "The pod's app label."; };
              };
            });
          };
          minecraft = lib.mkOption {
            default = null;
            description = "A Minecraft server: save and hold the world still over RCON while it's copied.";
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                namespace = lib.mkOption { type = lib.types.str; };
                app = lib.mkOption { type = lib.types.str; description = "The pod's app label."; };
                secret = lib.mkOption { type = lib.types.str; default = "minecraft-rcon"; };
                key = lib.mkOption { type = lib.types.str; default = "password"; description = "The secret's key holding the RCON password."; };
              };
            });
          };
        };
      }));
    };
  };

  config = lib.mkIf (cfg.services != { }) {
    assertions = [{
      assertion = copy.receive.enable;
      message = "site-failover needs dotfiles.standbyCopy.receive on this node.";
    }];

    dotfiles.standbyCopy.send = lib.mapAttrs (svc: s: {
      source = "/srv/ha/${svc}";
      to = s.peer;
      inherit (s) sqlite;
      # A part being written lives in tmp_* until it's renamed into place.
      exclude = s.exclude ++ lib.optional (s.clickhouse != null) "tmp_*";
      preCopy =
        if s.minecraft != null then rcon s.minecraft ''"save-off" "save-all flush"''
        else if s.clickhouse != null then clickhouse s.clickhouse "SYSTEM STOP MERGES"
        else s.preCopy;
      postCopy =
        if s.minecraft != null then rcon s.minecraft ''"save-on"''
        else if s.clickhouse != null then clickhouse s.clickhouse "SYSTEM START MERGES"
        else s.postCopy;
      onlyWhenActive = svc;
    }) (lib.filterAttrs (_: s: !s.stateless) cfg.services);

    systemd.services.site-failover = {
      description = "Site failover for services with files";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" "local-fs.target" ];
      path = [ pkgs.util-linux ];
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${./site-failover.py} ${configFile}";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
