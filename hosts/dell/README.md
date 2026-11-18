# dell

Dell PowerEdge T30 (Xeon E3, 32 GB, 240 GB SATA SSD, 4 TB HDD) in DK. A k3s
agent for x86 CI jobs and general compute, so the thinkcentre, which holds
DK's control plane and services, doesn't also carry the builds. Not an etcd
member and not a site-failover home: nothing on it has to survive the
machine, so there's no Borg job.

- **System disk** ([disko.nix](disko.nix)): LUKS (passphrase) with LVM, `/`
  (60 GB) and `/var/lib/rancher` (the rest, for containerd and CI) as separate
  volumes, so CI can't fill `/`. Wiped and remade by every install.
- **4 TB disk** ([storage-disk.nix](storage-disk.nix)): LUKS with a keyfile
  from SOPS, on `/srv/storage`, opened after boot and `nofail`. Formatted
  once (`install --format-storage`); no later install touches it. Nothing
  uses it yet.
- **Which device is which** is [disks.nix](disks.nix), read only at install
  time. The running system finds everything by label.
- **Nobody on site:** [boot-safety.nix](../../modules/nixos/boot-safety.nix)
  (boot counting, watchdog, reboot if not unlocked within 45 minutes, boot
  health check), unlock over SSH in the initrd from the DK LAN or through the
  edge, e1000e-guard for the onboard I219-LM.
- **Identity** is in `secrets/dell-bootstrap.yaml` (personal key only), not
  on the disk: the SSH host key (the age key comes from it), the initrd host
  key, the edge tunnel keys, the Nebula key and the k3s node password, made
  once by [bootstrap](bootstrap); and its tailnet identity, saved after the
  first boot by [save-state](save-state). The install puts all of it back,
  so a reinstalled dell is the same machine to everything else.

## Before the first install (once)

1. Sign the Nebula certificate (the CA key isn't in this repo):
   ```sh
   nebula-cert sign -version 2 -ca-crt lib/nebula/ca.crt -ca-key <ca.key> \
     -name dell -networks 10.99.0.6/24 -groups servers \
     -in-pub hosts/dell/nebula.pub -out-crt lib/nebula/dell.crt
   ```
2. `sops secrets/dell.yaml`: a Headscale pre-auth key
   (`headscale preauthkeys create --user <user> --expiration 24h`) and the k3s
   agent token (`sudo cat /var/lib/rancher/k3s/server/agent-token` on fuji).
3. Commit and merge, so the edge has the tunnel keys and comin deploys
   the same system the install puts on the machine.

## BIOS (F2 at boot)

- Boot mode UEFI, Secure Boot off.
- AC Power Recovery: **On**, so it comes back after a power cut.
- Wake-on-LAN: on (LAN only).
- SATA operation: AHCI (it came in RAID mode). The SSD on the lower SATA
  port, so it's `/dev/sda` and the HDD `/dev/sdb` as in disks.nix (the
  install script checks).
- The onboard NIC is named `lan0` by its MAC (configuration.nix), not by
  the firmware: this BIOS points its "Intel LOM" record at the wrong PCI
  address, so udev can't call it `eno1`. A new mainboard needs its MAC
  there.
- If there's an Intel ME/AMT setup (Ctrl+P at boot), it gives remote power
  and console over the LAN: worth setting up, reachable from the DK LAN only.

## Install

On the T30: boot the NixOS minimal installer from USB, plug in the network
cable, `sudo passwd root`, and note its address (`ip -br a`).

The first time, test the hardware from the installer before trusting it:
the RAM isn't ECC, and the SSD showed checksum errors under ZFS (most
likely from a faulty machine it was in before, but nothing proved it).
Memtest86+ from the installer's boot menu, one full pass. Then the SSD,
which this wipes:

```sh
sudo nix-shell -p fio --run 'fio --name=verify --filename=/dev/sda --direct=1 \
  --rw=write --bs=1M --size=100% --verify=crc32c --do_verify=1'
```

Any `verify:` error means the SSD returns wrong data: replace it.

From a clean checkout on the same LAN:

```sh
ssh-copy-id root@<LAN-IP>                          # so nothing asks for the password again
hosts/dell/install --format-storage root@<LAN-IP>  # the first time: both disks
```

It checks that everything above is in place and which disk is which, asks
for the system disk's passphrase, and says what it's about to wipe. After
the reboot, unlock it:

```sh
ssh -t -p 2222 -o HostKeyAlias=dell-initrd root@<LAN-IP>
```

Then, once:

- `hosts/dell/save-state` and commit, so its tailnet identity is kept too.
- A fixed DHCP lease on the MikroTik for its MAC.
- The check under "The SATA SSD" below, before CI goes on it.

## A new system disk

For an NVMe in place of the SATA SSD, or a dead system disk:

1. Put the disk in. For an NVMe, set `system = "/dev/nvme0n1"` in
   [disks.nix](disks.nix) and commit. Nothing else changes: the layout sizes
   itself to the disk, and the `nvme` driver is already in the initrd.
2. Boot the installer, `ssh-copy-id`, then `hosts/dell/install root@<LAN-IP>`
   (no `--format-storage`: the 4 TB disk and what's on it stay).
3. Unlock it. It comes up as the same node: same host keys, same addresses on
   Nebula and the tailnet, same k3s node, deployed by comin as before. Only
   the container images are pulled again.

`hosts/dell/install --format-storage` again only for a new HDD.

## The SATA SSD

Big writes on SATA SSDs have a history of making Linux crawl. What's set
against that here: small dirty-page limits (configuration.nix), dm-crypt
without its work queues and no `discard` mounts (disko.nix), CI VMs capped at
100 MB/s of writes (kata.nix), and CI on its own filesystem. No etcd or
database runs here, so a slow disk slows this node's own pods and nothing
else.

To see what this disk does, on dell, once after the install: 20 GB written
flat out where CI writes, while a small job on `/` does ten synced writes a
second.

```sh
sudo nix shell nixpkgs#fio -c fio \
  --name=flood --filename=/var/lib/rancher/stall-test.tmp --rw=write --bs=1M --size=20G --end_fsync=1 \
  --name=probe --filename=/var/tmp/stall-probe.tmp --rw=randwrite --bs=4k --size=64M \
    --fsync=1 --rate_iops=10 --time_based --runtime=300
sudo rm /var/lib/rancher/stall-test.tmp /var/tmp/stall-probe.tmp
cat /proc/pressure/io
```

Read the `sync` line under the `probe` job (its fsync latency).
A 99th percentile in the tens of milliseconds and a maximum under a second
is a disk that copes; a maximum of several seconds is the stall. If it
stalls: set `dotfiles.kata.ciIo.writeMBps` in configuration.nix (100 by
default) to well under what the flood job
averaged, and plan the NVMe.

## Unlocking later

```sh
unlock-via-edge dell     # through the edge, no tailnet needed
via-edge dell            # SSH, same way
```

## After it joins

In the infrastructure repo: its pod subnet (`kubectl get node dell -o
jsonpath='{.spec.podCIDR}'`) in every network policy that lists the nodes,
its tailnet address in Headscale's ACL, a CI runner slot, the Prometheus
targets and the outage page's node list. Then put its tailnet address in
`lib/edge-tunnel-remote.nix` instead of the `dell` alias.
