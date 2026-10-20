# When a node's disk goes under kubelet's eviction threshold (k3s: 5% free),
# kubelet evicts pods until it's back above it plus a minimum reclaim. k3s
# sets that minimum to 10% of the disk, 41 GiB on the thinkcentre's /home:
# on 2026-10-20 the CI pod's Docker disk took it under 5%, and evicting that
# one pod freed 30 GiB, but kubelet went on evicting nearly every pod on the
# node and then held DiskPressure (and its NoSchedule taint) for good, since
# nothing it could evict made up the rest (infrastructure,
# docs/incidents/2026-10-20-thinkcentre-disk-pressure.md).
#
# A small fixed minimum instead: the biggest user of the disk goes, the rest
# stays. The threshold stays k3s's own (no "%" here: systemd would read it as
# a specifier in ExecStart).
{ ... }:

{
  services.k3s.extraFlags = [
    "--kubelet-arg=eviction-minimum-reclaim=imagefs.available=2Gi,nodefs.available=2Gi"
  ];
}
