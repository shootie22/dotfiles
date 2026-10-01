# Fast disposable development VM for agentic coding.
# The guest is ordinary Debian; Nix only manages the host-side launcher/tooling.
{ config, lib, pkgs, ... }:

let
  cfg = config.modules.devvm;
  devScript = builtins.replaceStrings
    [
      "usage: devvm "
      "  devvm            "
      "  devvm claude"
      "  devvm codex"
      "  devvm --refresh"
      "◆ devvm"
      "devvm: "
      "run devvm from inside"
      "DEVVM —"
    ]
    [
      "usage: dev "
      "  dev              "
      "  dev claude"
      "  dev codex"
      "  dev --refresh"
      "◆ dev"
      "dev: "
      "run dev from inside"
      "DEV —"
    ]
    (builtins.readFile ../../scripts/devvm.sh);
  dev = pkgs.writeShellApplication {
    name = "dev";
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
    text = devScript;
  };
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
