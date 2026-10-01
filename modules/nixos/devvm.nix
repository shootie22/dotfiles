# Fast disposable development VM for agentic coding.
# The guest is ordinary Debian; Nix only manages the host-side launcher/tooling.
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.devvm;
  runtimeInputs = with pkgs; [
    cloud-utils
    coreutils
    curl
    gawk
    git
    gnugrep
    iproute2
    openssh
    qemu_kvm
    util-linux
    virtiofsd
  ];
  dev = pkgs.writeShellScriptBin "dev" ''
    export PATH=${lib.makeBinPath runtimeInputs}:$PATH
    exec ${pkgs.bash}/bin/bash ${../../scripts/devvm.sh} "$@"
  '';
in
{
  options.modules.devvm = {
    enable = lib.mkEnableOption "disposable agent development VM";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Host user allowed to use KVM for the dev environment.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ dev ];
    users.users.${cfg.user}.extraGroups = [ "kvm" ];
  };
}
