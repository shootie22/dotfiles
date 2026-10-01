# edge

The small public VPS: the third etcd vote, a TCP pass-through into Traefik in RO and DK, and the failover checkers. No services and no data. The plan behind it is in the infrastructure repo under [docs/ha](https://github.com/shootie22/infrastructure/tree/main/docs/ha).

It has to be replaceable in minutes, so the only thing that isn't rebuilt from this folder is its identity: the SSH host key. That key is encrypted in `secrets/edge-bootstrap.yaml` (personal age key only), and sops-nix derives the host's age key from it, so a reinstall keeps the same `known_hosts` entry and can still read `secrets/edge.yaml`.

## Install or replace

Follow the runbook in the infrastructure repo: [replace-edge.md](https://github.com/shootie22/infrastructure/blob/main/docs/ha/runbooks/replace-edge.md). In short: a Headscale pre-auth key into `secrets/edge.yaml`, then `hosts/edge/install <user>@<ip>` from a clean checkout. `hosts/edge/install --vm-test` does the whole install in a local VM, which is worth running after changes to `disko.nix` or the boot setup.

## Changes

Commit and push to `main`. comin on the edge picks it up within a minute or two and switches to it (`sudo comin status` shows what it runs). Kernel updates take effect at the next nightly reboot check, 04:00 Romanian time, and only if the kernel actually changed.

## Notes

- Disk: GPT with a BIOS boot partition and an ESP, GRUB on both, so it boots on legacy BIOS (OVH) and UEFI alike. No encryption: there's nothing on it worth protecting, and nobody to unlock it after a reboot.
- IPv4 by DHCP only. OVH's IPv6 is static and not set up yet.
- Logins: admin devices from `lib/admin-ssh-keys.nix` as user `edge`, no passwords anywhere, root login off.
