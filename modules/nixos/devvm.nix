# Fast disposable development VM for agentic coding.
# The guest is ordinary Debian; Nix only manages the host-side launcher/tooling.
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.devvm;
  devvm = pkgs.writeShellApplication {
    name = "devvm";
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
    text = builtins.readFile ../../scripts/devvm.sh;
  };
in
{
  options.modules.devvm = {
    enable = lib.mkEnableOption "disposable agent development VM";
    user = lib.mkOption {
      type = lib.types.str;
      description = "Host user allowed to use KVM for devvm.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ devvm ];
    users.users.${cfg.user}.extraGroups = [ "kvm" ];
  };
}
