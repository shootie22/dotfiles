# Docker + docker-compose, shared across hosts.
#
# Enable per-host with:
#   modules.docker.enable = true;
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.docker;
in
{
  options.modules.docker = {
    enable = lib.mkEnableOption "Docker container support";
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;
    # 25.11's default docker (28.x) is marked insecure/unmaintained; pin to
    # docker_29 instead of allowing insecure packages.
    virtualisation.docker.package = pkgs.docker_29;

    users.users.bro.extraGroups = [ "docker" ];

    environment.systemPackages = with pkgs; [
      docker-compose
    ];
  };
}
