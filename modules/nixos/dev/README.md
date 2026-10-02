# dev: disposable MicroVMs for untrusted projects

`dev` runs the current folder inside a throwaway NixOS MicroVM (microvm.nix +
QEMU). It's meant for code whose dependencies you don't trust, and for
agents with broad permissions.

```
dev                     shell in the VM, in the same directory
dev <cmd ...>           run a command: dev claude, dev codex, dev npm run dev
dev --nonet [cmd]       VM without any network device
dev allow [--ro] PATH   also mount PATH (at the same path) in this project's VM
dev allow --global PATH ...in every project's VM
dev deny PATH           remove a grant
dev allowed             list grants that apply here
dev stop                stop this folder's VM now
```

- **What the VM sees**: the project (the git root if you're inside a repo,
  else the current directory), mounted read-write at the same absolute path.
  It also sees anything you granted with `dev allow`. Nothing else from your
  home directory is visible.
- **Sessions**: a second `dev` in the same folder joins the running VM. The
  VM stays up for 5 minutes after the last session exits (`DEV_LINGER=<s>`),
  so repeated `dev <cmd>` calls skip the boot.
- **Dev servers**: TCP ports the VM listens on (>= 1024) are forwarded to the
  same port on the host's `127.0.0.1` while that port is free. The
  `http://localhost:5173` link your tool prints just works. Forwarded ports are
  listed in `$XDG_RUNTIME_DIR/dev/<project>/ports`.
- **Grants** live in `~/.config/dev/allow` (tab-separated
  `project  rw|ro  path`; project `*` means all). The VM can't see or edit that
  file. A change applies on your next `dev`: an idle VM restarts with it, and
  one still in use by other sessions picks it up once they exit.

## Agents

Put credentials meant for VMs in `~/.config/dev/env` (`KEY=VALUE` lines). They
are exported in every session:

```sh
claude setup-token            # on the host; prints a long-lived token
echo 'CLAUDE_CODE_OAUTH_TOKEN=...' >> ~/.config/dev/env
echo 'OPENAI_API_KEY=...'          >> ~/.config/dev/env   # or `codex login` inside a VM
chmod 600 ~/.config/dev/env
```

Your host logins (`~/.claude`, `~/.codex`) are never copied into a VM. Code
running in a VM can read anything its agent can use, so give VMs their own
tokens that you can revoke separately.

Inside the VM, Claude Code runs with file edits and shell commands
auto-approved, but `rm`, `ssh`, `scp`, `rsync`, `git push`, `git reset --hard`
and similar commands still ask (`/etc/claude-code/managed-settings.json` in
`guest.nix`). This is pattern matching and therefore best-effort; the VM is the
actual boundary. Codex runs with its defaults.

The VM has no SSH keys and no sudo. Push from the host.

## How it is isolated

| | |
|---|---|
| Filesystem | One rootless `virtiofsd` per shared folder; read-only grants and `/nix/store` are enforced by `virtiofsd --readonly` on the host. Guest uid 1000 maps to you. |
| Network | QEMU connects to `/run/dev-net/passt.sock`; systemd starts a `passt` for each VM as the `dev-net` user. The host nftables table `inet dev_net` rejects everything from that user except the public internet: no host services, LAN, Tailscale, Docker networks or IPv6. The guest's root can't change this. DNS is 1.1.1.1/9.9.9.9. |
| Control | SSH over vsock, key in a per-launch read-only share. No TCP SSH. |
| Git | `.git/config` and `.git/hooks` are bind-mounted read-only in the guest. Without that, the VM could plant a hook or `core.fsmonitor` command that runs on the host the next time you use git there. Because of it, `git config` edits fail inside the VM; make them on the host. |

## Residual risks

Treat everything the VM writes as untrusted on the host:

- Don't run the project's scripts on the host (`npm install`, `make`,
  `.envrc` with direnv, editor tasks). The VM may have changed them.
- Git protection covers the repository's own `.git`. If a project wasn't a
  repo, the VM can `git init` one, and nested repositories created by the VM
  aren't protected either. Be careful running host git in those.
- Read-write grants (`dev allow PATH`) give the VM the same power over PATH.
- The VM can open any localhost port that is free on the host (auto-forwarding).

## Files

- `default.nix`: host side (passt socket/service, nftables, the `dev` command)
- `guest.nix`: the VM image
- `dev.sh`: launcher. Per-project state lives in
  `~/.local/share/dev/<name>-<hash>/`: `home.img` (persistent `/home/dev`),
  `vm.log` (serial console), `virtiofs.log`, `supervisor.log`. Delete that
  directory to reset a project's VM.
