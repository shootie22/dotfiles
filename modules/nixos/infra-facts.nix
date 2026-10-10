# What this host runs, written out from its own evaluated config as metrics
# for node-exporter's textfile collector, so Hub (infra-hub,
# docs/design.md) knows each server's parts without anyone listing
# them, its NixOS version, and every port its firewall lets in with the file
# that opened it. It changes when the config does, and only exists where it's
# deployed.
{ config, options, lib, pkgs, ... }:

let
  host = config.networking.hostName;
  mesh = import ../../lib/nebula.nix;
  me = mesh.hosts.${host} or { };
  on = path: lib.attrByPath path false config;
  port = path: toString (lib.attrByPath path 0 config);
  esc = lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" " " ];
  label = attrs: "{" + lib.concatStringsSep "," (lib.mapAttrsToList (k: v: "${k}=\"${esc (toString v)}\"") attrs) + "}";

  services = lib.filterAttrs (_: s: s.enabled) {
    nebula = { enabled = on [ "dotfiles" "nebulaMesh" "enable" ]; port = if me.lighthouse or false then toString mesh.port else "4241"; };
    comin = { enabled = on [ "services" "comin" "enable" ]; port = port [ "services" "comin" "exporter" "port" ]; };
    alert-relay = { enabled = on [ "dotfiles" "alertRelay" "enable" ]; port = port [ "dotfiles" "alertRelay" "port" ]; };
    ro-failover = { enabled = on [ "dotfiles" "failoverChecker" "enable" ]; port = port [ "dotfiles" "failoverChecker" "port" ]; };
    element-front = { enabled = on [ "dotfiles" "frontChecker" "enable" ]; port = port [ "dotfiles" "frontChecker" "port" ]; };
    nameservers = { enabled = on [ "dotfiles" "nsChecker" "enable" ]; port = port [ "dotfiles" "nsChecker" "port" ]; };
    site-failover = {
      enabled = (lib.attrByPath [ "dotfiles" "siteFailover" "services" ] { } config) != { };
      port = port [ "dotfiles" "siteFailover" "port" ];
    };
    game-relay = { enabled = on [ "dotfiles" "gameRelay" "enable" ]; port = ""; };
  };

  # The firewall as evaluated: every open port, per interface ("*" for all
  # of them), with the file that opened it. Files are paths in this repo, or
  # in nixpkgs for ports a NixOS module opens by itself.
  fw = options.networking.firewall;
  rel = f:
    let
      m = builtins.match ".*-source/(.*)" (toString f);
      p = if m == null then toString f else builtins.head m;
    in
    if lib.hasSuffix ".nix" p then p else p + "/default.nix"; # a folder module is its default.nix
  repoOf = p: if lib.hasPrefix "nixos/" p || lib.hasPrefix "pkgs/" p then "nixpkgs" else "dotfiles";
  plain = v: lib.isAttrs v && !(v ? _type);
  ints = v: if lib.isList v then lib.filter lib.isInt v else [ ];
  defsOf = iface: proto: d: map (p: { name = "${iface}|${proto}|${toString p}"; value = rel d.file; }) (ints d.value);
  ifaceDefs = d: lib.optionals (plain d.value) (lib.concatLists (lib.mapAttrsToList
    (iface: c: lib.optionals (plain c) (
      defsOf iface "tcp" { inherit (d) file; value = c.allowedTCPPorts or [ ]; }
      ++ defsOf iface "udp" { inherit (d) file; value = c.allowedUDPPorts or [ ]; }))
    d.value));
  where = lib.listToAttrs (
    lib.concatMap (defsOf "*" "tcp") fw.allowedTCPPorts.definitionsWithLocations
    ++ lib.concatMap (defsOf "*" "udp") fw.allowedUDPPorts.definitionsWithLocations
    ++ lib.concatMap ifaceDefs fw.interfaces.definitionsWithLocations);
  cfg = config.networking.firewall;
  open = lib.optionals cfg.enable (
    map (p: { iface = "*"; proto = "tcp"; port = p; }) cfg.allowedTCPPorts
    ++ map (p: { iface = "*"; proto = "udp"; port = p; }) cfg.allowedUDPPorts
    ++ lib.concatLists (lib.mapAttrsToList (iface: c:
      map (p: { inherit iface; proto = "tcp"; port = p; }) c.allowedTCPPorts
      ++ map (p: { inherit iface; proto = "udp"; port = p; }) c.allowedUDPPorts) cfg.interfaces));
  portLine = o: let file = where."${o.iface}|${o.proto}|${toString o.port}" or ""; in
    "infra_firewall_port${label { host = host; iface = o.iface; proto = o.proto; port = o.port; file = file; repo = if file == "" then "" else repoOf file; }} 1\n";

  # Every service, container runtime or program this host's own config turns
  # on (not NixOS's defaults), with its package, version and description,
  # and the file that turned it on: Hub's Tech page (infra-hub). Read from
  # the evaluated options, so nothing here lists them.
  techOf = group:
    let
      opts = options.${group} or { };
      one = n: o:
        if !(lib.isAttrs o && o ? enable && lib.isOption o.enable) then [ ] else
        let
          # Only what one of our files sets, read from the definitions:
          # touching the value of a renamed option aborts the evaluation,
          # and tryEval can't catch that.
          ours = lib.filter (d: repoOf (rel d.file) == "dotfiles") (o.enable.definitionsWithLocations or [ ]);
          r = builtins.tryEval (
            if ours != [ ] && config.${group}.${n}.enable == true then
              let
                defs = lib.filter (d: d.value == true) ours;
                pkg = lib.attrByPath [ group n "package" ] null config;
                isPkg = pkg != null && lib.isDerivation pkg;
              in
              lib.optional (defs != [ ]) {
                option = "${group}.${n}";
                file = rel (lib.head defs).file;
                pname = if isPkg then pkg.pname or (lib.getName pkg) else n;
                version = if isPkg then pkg.version or (lib.getVersion pkg) else "";
                description = if isPkg then pkg.meta.description or "" else "";
              }
            else [ ]);
        in
        if r.success then r.value else [ ];
    in
    lib.concatLists (lib.mapAttrsToList one opts);
  pkgTech = option: pkg: file: { inherit option file; pname = pkg.pname or (lib.getName pkg); version = pkg.version or (lib.getVersion pkg); description = pkg.meta.description or ""; };
  # Turned on by having entries rather than an enable: the first of our
  # files that adds one.
  setBy = opt: lib.findFirst (d: repoOf (rel d.file) == "dotfiles") null (opt.definitionsWithLocations or [ ]);
  fromSet = option: opt: value: pkg:
    let d = setBy opt; in lib.optional (d != null && value != { }) (pkgTech option pkg (rel d.file));
  tech = lib.concatMap techOf [ "services" "virtualisation" "programs" ]
    ++ fromSet "services.borgbackup" options.services.borgbackup.jobs config.services.borgbackup.jobs pkgs.borgbackup
    ++ lib.optionals (options ? sops) (fromSet "sops.secrets" options.sops.secrets config.sops.secrets pkgs.sops)
    # The base every host has, from NixOS itself.
    ++ [
      (pkgTech "boot.kernelPackages" config.boot.kernelPackages.kernel "")
      (pkgTech "nix.package" config.nix.package "")
      (pkgTech "systemd.package" config.systemd.package "")
    ]
    # Ours, around a package of their own.
    ++ lib.optional (lib.attrByPath [ "dotfiles" "kata" "enable" ] false config) (pkgTech "dotfiles.kata" pkgs.kata-runtime "modules/nixos/kata.nix")
    ++ lib.optional (lib.attrByPath [ "dotfiles" "nebulaMesh" "enable" ] false config) (pkgTech "dotfiles.nebulaMesh" pkgs.nebula "modules/nixos/nebula-mesh.nix");
  techLine = t: "infra_tech_info${label { host = host; inherit (t) option file pname version description; }} 1\n";

  text = (''
    # HELP infra_host_info What this server is, from its NixOS config.
    # TYPE infra_host_info gauge
    infra_host_info${label {
      host = host;
      mesh_ip = me.ip or "";
      lighthouse = if me.lighthouse or false then "true" else "false";
      k3s_api = if me.api or false then "true" else "false";
      system = pkgs.stdenv.hostPlatform.system;
    }} 1
    # HELP infra_host_service A part this server runs outside Kubernetes, and its port.
    # TYPE infra_host_service gauge
  '' + lib.concatStrings (lib.mapAttrsToList (name: s: ''
    infra_host_service${label { host = host; service = name; port = s.port; }} 1
  '') services) + ''
    # HELP infra_nixos_info The NixOS this server runs.
    # TYPE infra_nixos_info gauge
    infra_nixos_info${label { host = host; version = config.system.nixos.version; codename = config.system.nixos.codeName; revision = toString (config.system.nixos.revision or ""); }} 1
    # HELP infra_firewall_port A port the firewall lets in, and the file that opened it.
    # TYPE infra_firewall_port gauge
  '' + lib.concatStrings (map portLine open) + ''
    # HELP infra_tech_info Software this host's config turns on: package, version, what it is, and the file.
    # TYPE infra_tech_info gauge
  '' + lib.concatStrings (map techLine tech));
  facts = pkgs.writeText "infra_facts.prom" text;
in
{
  # The facts as text, to read them without building anything:
  #   nix eval --raw .#nixosConfigurations.<host>.config.dotfiles.infraFacts.text
  options.dotfiles.infraFacts.text = lib.mkOption { type = lib.types.str; readOnly = true; internal = true; };
  config.dotfiles.infraFacts.text = text;

  # The textfile collector reads every *.prom file in this folder. A real
  # copy, not a link: node-exporter runs in a container that sees the host
  # under /host/root, where a link into /nix/store would point nowhere.
  config.system.activationScripts.infraFacts = ''
    mkdir -p /var/lib/node-exporter-textfile
    install -m 0644 ${facts} /var/lib/node-exporter-textfile/.infra_facts.prom.tmp
    mv /var/lib/node-exporter-textfile/.infra_facts.prom.tmp /var/lib/node-exporter-textfile/infra_facts.prom
  '';
}
