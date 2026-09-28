# thinkcentre

Debian 13, not NixOS: nothing here is applied automatically. This file is the
record of the machine's hand-managed state, so it can be rebuilt or audited.

## K3s agent

Installed with the upstream script (`/usr/local/bin/k3s`, unit
`k3s-agent.service`, server URL and token in the root-only
`/etc/systemd/system/k3s-agent.service.env`).

```sh
curl -sfL https://get.k3s.io | K3S_URL=https://100.64.0.1:6443 K3S_TOKEN=<agent token> \
  INSTALL_K3S_VERSION=v1.35.8+k3s1 sh -s - agent --node-external-ip=100.64.0.4
```

## Tailscale

Joined to Headscale (`https://hs.radunenu.com`). Preferences persist in
tailscaled's state, so these run once:

```sh
sudo tailscale up --login-server https://hs.radunenu.com
# Reach Fuji's LAN API address (the kubernetes Service endpoint) via Fuji.
sudo tailscale set --accept-routes
```

Debian's default `rp_filter` is loose (2) on new interfaces, which routed
replies over `tailscale0` need.

## Units kept in this directory

Copy to `/etc/systemd/system/`, `systemctl daemon-reload`, then enable:

- `k3s-tailnet-guard.service`: keeps Tailscale transport out of the pod
  network (see `modules/nixos/k3s-tailnet-guard.nix`).
- `thinkcentre-borg-backup.service` / `.timer`: Borg backup of `/home/main`
  and the Minecraft world to the Mac mini, running `bin/backup-home-main`
  from this checkout. The live unit also has a drop-in
  (`thinkcentre-borg-backup.service.d/`) treating Borg's warning exit status 1
  as success.
