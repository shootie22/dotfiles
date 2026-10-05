# thinkcentre

NixOS since 5 Oct 2026, on trial: it runs from the `nixos` volume next to
Debian, and Debian is still there as the fallback until the trial ends
(infrastructure docs/ha/runbooks/thinkcentre-reinstall.md). The NixOS config
is configuration.nix, hardware-configuration.nix and boot-safety.nix, deployed
by comin like the other servers.

The rest of this file is the record of the Debian install's hand-managed
state, kept until Debian is retired.

## Remote disk unlock (NixOS)

The initrd's SSH listens on 2222 on the LAN. From an admin device:

```sh
thinkcentre-unlock    # finds it through mixi by MAC, Debian or NixOS
```

The NixOS initrd gets a different LAN address than Debian did, so don't rely
on a fixed one. Its host key is `ED25519
SHA256:nnd7PFVWutz2G/v4n3Z7sRG58d10PW06Rv9xsiHrM0U` (known_hosts alias
`thinkcentre-initrd`). Once NixOS is the default, `unlock-via-edge thinkcentre`
works too.

## K3s agent

Installed with the upstream script (`/usr/local/bin/k3s`, unit
`k3s-agent.service`, server URL and token in the root-only
`/etc/systemd/system/k3s-agent.service.env`).

```sh
curl -sfL https://get.k3s.io | K3S_URL=https://100.64.0.1:6443 K3S_TOKEN=<agent token> \
  INSTALL_K3S_VERSION=v1.35.8+k3s1 sh -s - agent --node-external-ip=100.64.0.4
```

The kubelet gets a resolv.conf without search domains (see
`modules/nixos/k3s-dns.nix` for why):

```sh
sudo install -m 0644 k3s-resolv.conf /etc/k3s-resolv.conf
sudo install -D -m 0600 k3s-config.yaml /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s-agent
```

## SSH access

Logins are granted to the admin devices in `lib/admin-ssh-keys.nix`, plus the
Borg key (forced `borg serve`) that must stay as it is. Rebuild main's list
from the repo, keeping the Borg line:

```sh
cd ~/.ssh && cp -p authorized_keys authorized_keys.bak-$(date +%F)
{ grep -o '"ssh-[^"]*"' ~/git/dotfiles/lib/admin-ssh-keys.nix | tr -d '"'
  grep 'borg serve' authorized_keys.bak-$(date +%F); } > authorized_keys.new
chmod 600 authorized_keys.new && mv authorized_keys.new authorized_keys
```

Password logins are off (`/etc/ssh/sshd_config.d/10-keys-only.conf`):

```
PasswordAuthentication no
KbdInteractiveAuthentication no
```

## Remote disk unlock (Debian)

The root disk is LUKS; nobody is on site to type the passphrase. An early-boot
SSH server (dropbear-initramfs) takes it instead, reachable on the LAN only, so
unlock through mixi (from an admin device):

```sh
ssh -J mixa@100.64.0.2 -p 2222 root@192.168.88.250   # runs cryptroot-unlock
```

Host key: `ED25519 SHA256:kSLy0h8gLWQbfbraKjXMFEjfXYUvHEI46eKoUzCeqTs`. The
console prompt keeps working. Setup:

```sh
sudo apt-get install -y dropbear-initramfs
grep -o '"ssh-[^"]*"' ~/git/dotfiles/lib/admin-ssh-keys.nix | tr -d '"' \
  | sudo tee /etc/dropbear/initramfs/authorized_keys >/dev/null
sudo chmod 600 /etc/dropbear/initramfs/authorized_keys
echo 'DROPBEAR_OPTIONS="-p 2222 -s -j -k -I 120 -c cryptroot-unlock"' \
  | sudo tee /etc/dropbear/initramfs/dropbear.conf
echo 'IP=:::::enp0s31f6:dhcp' | sudo tee /etc/initramfs-tools/conf.d/remote-unlock
sudo update-initramfs -u -k all
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
