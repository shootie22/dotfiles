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
      ''BASE_VERSION="1"''
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
      ''  - [ bash, -lc, 'mkdir -p /work /home/dev/.claude /home/dev/.codex /home/dev/.local/npm' ]''
      ''  - [ bash, -lc, 'mount -t virtiofs claude /home/dev/.claude' ]''
      ''  - [ bash, -lc, 'mount -t virtiofs codex /home/dev/.codex' ]''
      ''  - [ bash, -lc, 'printf "repo /work virtiofs rw,nofail 0 0\nclaude /home/dev/.claude virtiofs rw,nofail 0 0\ncodex /home/dev/.codex virtiofs rw,nofail 0 0\n" >> /etc/fstab' ]''
      ''if ! wait_for_ssh "$port"; then
  cat "$run_dir/qemu.log" >&2 || true
  die "VM did not become reachable"
fi

log "$repo_name → $guest_dir"''
      ''ssh "${ssh_base_args[@]}" dev@127.0.0.1 'sudo poweroff' >/dev/null 2>&1 || true
exit "$rc"''
    ]
    [
      ''BASE_VERSION="2"''
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
      ''  - [ bash, -lc, 'mkdir -p /work /mnt/devstate/claude /mnt/devstate/codex /home/dev/.claude /home/dev/.codex /home/dev/.local/npm' ]''
      ''  - [ bash, -lc, 'mount -t virtiofs claude /mnt/devstate/claude' ]''
      ''  - [ bash, -lc, 'mount -t virtiofs codex /mnt/devstate/codex' ]''
      ''  - [ bash, -lc, 'printf "repo /work virtiofs rw,nofail 0 0\nclaude /mnt/devstate/claude virtiofs rw,nofail 0 0\ncodex /mnt/devstate/codex virtiofs rw,nofail 0 0\n" >> /etc/fstab' ]''
      ''if ! wait_for_ssh "$port"; then
  cat "$run_dir/qemu.log" >&2 || true
  die "VM did not become reachable"
fi

# Keep agent runtime state on the VM's native filesystem. Only credentials are
# persisted through the host-backed virtiofs directories.
ssh "${ssh_base_args[@]}" dev@127.0.0.1 'mkdir -p "$HOME/.claude" "$HOME/.codex"; [ ! -f /mnt/devstate/claude/.credentials.json ] || cp /mnt/devstate/claude/.credentials.json "$HOME/.claude/.credentials.json"; [ ! -f /mnt/devstate/codex/auth.json ] || cp /mnt/devstate/codex/auth.json "$HOME/.codex/auth.json"; chmod 600 "$HOME/.claude/.credentials.json" "$HOME/.codex/auth.json" 2>/dev/null || true'

log "$repo_name → $guest_dir"''
      ''ssh "${ssh_base_args[@]}" dev@127.0.0.1 'mkdir -p /mnt/devstate/claude /mnt/devstate/codex; [ ! -f "$HOME/.claude/.credentials.json" ] || cp "$HOME/.claude/.credentials.json" /mnt/devstate/claude/.credentials.json; [ ! -f "$HOME/.codex/auth.json" ] || cp "$HOME/.codex/auth.json" /mnt/devstate/codex/auth.json' >/dev/null 2>&1 || true
ssh "${ssh_base_args[@]}" dev@127.0.0.1 'sudo poweroff' >/dev/null 2>&1 || true
exit "$rc"''
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
