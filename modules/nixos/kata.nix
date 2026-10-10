# Kata Containers for k3s: pods with `runtimeClassName: kata` run in their
# own small VM (QEMU + KVM) with their own kernel, so a container escape lands
# in a throwaway VM, not on this machine. Used for CI jobs (infrastructure
# kubernetes/services/ci-runner), where friends' workflows run next to mine.
#
# The RuntimeClass itself is in the infrastructure repo; this only gives k3s's
# containerd the `kata` handler.
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.kata;
  kata = pkgs.kata-runtime;

  # The packaged QEMU config, tightened:
  # - enable_annotations = []: pods can't change hypervisor settings (paths,
  #   kernel params) through annotations.
  # - seccompsandbox: QEMU's own seccomp filter (no spawning programs).
  # - sandbox_cgroup_only + static_sandbox_resource_mgmt: the VM is sized from
  #   the pod's limits at start, and QEMU and virtiofsd sit in the pod's
  #   cgroup, so the pod's CPU and memory limits cap the whole VM.
  # - default_memory/vcpus: the VM's base on top of the limits, matched by the
  #   RuntimeClass overhead.
  # - valid_virtio_fs_daemon_paths: the package points virtio_fs_daemon at
  #   virtiofsd but leaves QEMU's path in the allow list, which Kata rejects.
  kataConfig = pkgs.runCommand "kata-configuration.toml" { } ''
    src=${kata}/share/defaults/kata-containers/configuration-qemu.toml
    daemon=$(sed -n 's/^virtio_fs_daemon *= *"\(.*\)"/\1/p' $src)
    sed \
      -e "s|^rootless = .*|rootless = ${lib.boolToString cfg.rootlessVmm}|" \
      -e 's|^enable_annotations = .*|enable_annotations = []|' \
      -e 's|^seccompsandbox = .*|seccompsandbox = "on,obsolete=deny,spawn=deny,resourcecontrol=deny"|' \
      -e 's|^sandbox_cgroup_only = .*|sandbox_cgroup_only = true|' \
      -e 's|^static_sandbox_resource_mgmt = .*|static_sandbox_resource_mgmt = true|' \
      -e 's|^default_memory = .*|default_memory = ${toString cfg.baseMemory}|' \
      -e 's|^default_vcpus = .*|default_vcpus = 1|' \
      -e 's|^disable_guest_seccomp = .*|disable_guest_seccomp = false|' \
      -e "s|^valid_virtio_fs_daemon_paths *=.*|valid_virtio_fs_daemon_paths = [\"$daemon\"]|" \
      $src > $out
    for want in 'enable_annotations = \[\]' 'sandbox_cgroup_only = true' \
        'static_sandbox_resource_mgmt = true' 'seccompsandbox = "on' \
        'disable_guest_seccomp = false' "valid_virtio_fs_daemon_paths = \[\"/nix/store/"; do
      grep -q "^$want" $out || { echo "kata config: no line '$want'" >&2; exit 1; }
    done
  '';

  # k3s writes containerd's config from its own template ("base"); this adds
  # the kata runtime after it. No pod_annotations, so no io.katacontainers.*
  # annotation reaches Kata. privileged_without_host_devices: a privileged
  # container in the VM (the CI Docker daemon) gets the VM's devices, not
  # this machine's.
  containerdTemplate = pkgs.writeText "config-v3.toml.tmpl" ''
    {{ template "base" . }}

    [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata]
      runtime_type = "io.containerd.kata.v2"
      runtime_path = "${kata}/bin/containerd-shim-kata-v2"
      privileged_without_host_devices = true
      [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata.options]
        ConfigPath = "${kataConfig}"
  '';
in
{
  options.dotfiles.kata = {
    enable = lib.mkEnableOption "the Kata Containers runtime for k3s";
    rootlessVmm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run QEMU as a throwaway unprivileged user per VM (Kata creates it
        with useradd), so a guest that escapes QEMU lands as nobody.
      '';
    };
    baseMemory = lib.mkOption {
      type = lib.types.int;
      default = 512;
      description = "MiB each Kata VM gets on top of its pod's memory limits.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "vhost_vsock" "vhost_net" ];

    systemd.tmpfiles.settings."10-k3s-kata"."/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl"."L+".argument =
      "${containerdTemplate}";

    # containerd reads the template only when k3s starts.
    systemd.services.k3s.restartTriggers = [ containerdTemplate ];

    # Kata adds and removes the per-VM QEMU users with shadow's tools.
    systemd.services.k3s.path = lib.mkIf cfg.rootlessVmm [ pkgs.shadow ];

    environment.systemPackages = [ kata ];
  };
}
