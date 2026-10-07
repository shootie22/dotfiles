# What this host runs, written out from its own evaluated config as metrics
# for node-exporter's textfile collector, so Hub (infrastructure repo,
# docs/platform/design.md) knows each server's parts without anyone listing
# them. It changes when the config does, and only exists where it's deployed.
{ config, lib, pkgs, ... }:

let
  host = config.networking.hostName;
  mesh = import ../../lib/nebula.nix;
  me = mesh.hosts.${host} or { };
  on = path: lib.attrByPath path false config;
  port = path: toString (lib.attrByPath path 0 config);
  esc = lib.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ];
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

  facts = pkgs.writeText "infra_facts.prom" (''
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
  '') services));
in
{
  # The textfile collector reads every *.prom file in this folder. A real
  # copy, not a link: node-exporter runs in a container that sees the host
  # under /host/root, where a link into /nix/store would point nowhere.
  system.activationScripts.infraFacts = ''
    mkdir -p /var/lib/node-exporter-textfile
    install -m 0644 ${facts} /var/lib/node-exporter-textfile/.infra_facts.prom.tmp
    mv /var/lib/node-exporter-textfile/.infra_facts.prom.tmp /var/lib/node-exporter-textfile/infra_facts.prom
  '';
}
