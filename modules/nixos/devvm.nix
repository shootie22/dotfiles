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
      ''remote="cd $quoted_dir && export DEVVM_REPO=$quoted_repo && exec $quoted_cmd"''
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
      ''remote="cd $quoted_dir && export DEVVM_REPO=$quoted_repo && export PATH=\$HOME/.local/npm/bin:\$HOME/.local/bin:\$PATH && exec $quoted_cmd"''
    ]
    (builtins.readFile ../../scripts/devvm.sh);
  dev = pkgs.writeShellScriptBin "dev" ''
    export PATH=${lib.makeBinPath runtimeInputs}:$PATH
    ${devScript}
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
