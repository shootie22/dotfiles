# Splits a server's memory three ways, so that nothing the cluster runs can
# take the host down and nothing the host runs can push out a service:
#
# - core: the OS, k3s (kubelet, etcd, containerd), sshd, tailscale. Never
#   limited, and the last things the kernel's OOM killer would pick.
# - host work: Nix builds and comin, Borg, weekly-update, tofu-apply, all in
#   host-work.slice. A fixed memory budget, and the lowest CPU and disk
#   share: a kernel build on a busy node runs slower instead of starving
#   anything, and if it outgrows its budget it's the one that fails.
# - pods: whatever is left. kubelet is told about the other two
#   (systemReserved), so it never schedules pods into them, and starts
#   evicting before the node runs out (evictionHard memory.available). It
#   evicts pods that use more than they asked for first, so a service that
#   stays within its requests is never evicted for someone else.
#
# k3s sets evictionHard to the disk thresholds only, which left nodes with
# no memory threshold at all; the drop-in below repeats k3s's disk values
# next to the memory one. Sizes come from each node's measured use outside
# pods (2026-10-30 to 2026-11-06).
{ config, lib, pkgs, ... }:

let
  cfg = config.dotfiles.nodeBudget;
  mib = n: "${toString n}Mi";

  kubeletConfig = pkgs.writeText "kubelet-node-budget.conf" (builtins.toJSON {
    apiVersion = "kubelet.config.k8s.io/v1beta1";
    kind = "KubeletConfiguration";
    systemReserved.memory = mib (cfg.coreMiB + cfg.hostWorkMiB);
    evictionHard = {
      "memory.available" = mib cfg.evictionMiB;
      "nodefs.available" = "5%";
      "imagefs.available" = "5%";
    };
  });

  hostWorkUnits =
    [ "nix-daemon" "comin" "nix-gc" "nix-optimise" ]
    ++ map (job: "borgbackup-job-${job}") (lib.attrNames config.services.borgbackup.jobs)
    ++ lib.optional (config.dotfiles.weeklyUpdate.enable or false) "weekly-update"
    ++ lib.optional (config.dotfiles.tofuApply.enable or false) "tofu-apply";
in
{
  options.dotfiles.nodeBudget = {
    coreMiB = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Memory kept for the OS and k3s itself, in MiB.";
    };
    hostWorkMiB = lib.mkOption {
      type = lib.types.ints.positive;
      description = "Memory for host-work.slice (builds, backups), in MiB. Its hard limit.";
    };
    evictionMiB = lib.mkOption {
      type = lib.types.ints.positive;
      description = "kubelet evicts pods when less than this is free, in MiB.";
    };
  };

  config = {
    services.k3s.extraFlags = [ "--kubelet-arg=config=${kubeletConfig}" ];

    systemd.slices.host-work = {
      description = "Builds and backups: whatever the host does for itself";
      sliceConfig = {
        CPUWeight = 20;
        IOWeight = 20;
        # Reclaimed and slowed down from here on, killed only past the max.
        MemoryHigh = mib (cfg.hostWorkMiB * 85 / 100);
        MemoryMax = mib cfg.hostWorkMiB;
      };
    };
    systemd.services = lib.genAttrs hostWorkUnits (_: {
      serviceConfig.Slice = "host-work.slice";
    }) // {
      # kubelet already gives itself -999; containerd, which k3s starts,
      # inherits this. Containers get their own score from kubelet.
      k3s.serviceConfig.OOMScoreAdjust = -999;
      tailscaled.serviceConfig.OOMScoreAdjust = lib.mkIf config.services.tailscale.enable (-900);
    };

    # IOWeight above, and the idle IO class Borg and the standby copies ask
    # for, only work under BFQ; the default schedulers ignore them. Spinning
    # disks only (the thinkcentre's 4 TB): on NVMe BFQ costs CPU and adds
    # latency etcd would feel, so those keep "none". Setting it loads the
    # module.
    services.udev.extraRules = ''
      ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    '';
  };
}
