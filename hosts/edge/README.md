# edge

The small public VPS: the third etcd vote, a TCP pass-through into Traefik in RO and DK, and the failover checkers. No services and no data. The plan behind it is in the infrastructure repo under [docs/ha](https://github.com/shootie22/infrastructure/tree/main/docs/ha).

It has to be replaceable in minutes, so the only thing that isn't rebuilt from this folder is its identity: the SSH host key. That key is encrypted in `secrets/edge-bootstrap.yaml` (personal age key only), and sops-nix derives the host's age key from it, so a reinstall keeps the same `known_hosts` entry and can still read `secrets/edge.yaml`.

## Install or replace

Needs the personal age key (`~/.config/sops/age/keys.txt`, copy in Bitwarden).

1. Put a Headscale pre-auth key into `secrets/edge.yaml` (`tailscale_authkey`). On fuji:
   ```sh
   sudo kubectl -n headscale exec deploy/headscale -- headscale preauthkeys create --user <user> --expiration 1h
   ```
2. Install. This wipes the target's disk and asks you to type the address again first:
   ```sh
   hosts/edge/install root@<ip>
   ```
3. If it replaced an older edge: remove the old node in Headscale, point the edge DNS record at the new IP in the infrastructure repo (OpenTofu), and cancel the old VPS.

`hosts/edge/install --vm-test` does the whole install in a local VM, which is worth running after changes to `disko.nix` or the boot setup.

## Rebuild after changes

```sh
nixos-rebuild switch --flake .#edge --target-host edge@<ip> --use-remote-sudo
```

## Notes

- Disk: GPT with a BIOS boot partition and an ESP, GRUB on both, so it boots on legacy BIOS (OVH) and UEFI alike. No encryption: there's nothing on it worth protecting, and nobody to unlock it after a reboot.
- IPv4 by DHCP only. OVH's IPv6 is static and not set up yet.
- Logins: admin devices from `lib/admin-ssh-keys.nix` as user `edge`, no passwords anywhere, root login off.
