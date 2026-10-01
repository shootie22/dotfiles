#!/usr/bin/env bash
set -euo pipefail

DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
DEBIAN_SUMS_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
BASE_VERSION="2"
VM_RAM_MB="${DEVVM_RAM_MB:-6144}"
VM_CPUS="${DEVVM_CPUS:-4}"

usage() {
  cat <<'USAGE'
usage: dev [--refresh] [--help] [command ...]

Run a disposable Debian development VM for the current git repository.
The current repo is mounted at /work; Claude/Codex credentials persist separately.

  dev            enter an interactive shell
  dev claude     start Claude directly
  dev codex      start Codex directly
  dev --refresh  rebuild the cached base VM (keeps agent auth)
USAGE
}

log() { printf '\033[1;35m◆ dev\033[0m %s\n' "$*"; }
die() { printf 'dev: %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
  esac
done

refresh=0
if [ "${1:-}" = "--refresh" ]; then
  refresh=1
  shift
fi

command_args=("$@")

[ "$(uname -m)" = "x86_64" ] || die "this setup currently supports x86_64 hosts only"
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
  die "/dev/kvm is not accessible; log out/in after joining the kvm group"
fi

repo="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || die "run dev from inside a git repository"
repo="$(realpath "$repo")"
current="$(realpath "$PWD")"
repo_name="$(basename "$repo")"
if [ "$current" = "$repo" ]; then
  guest_dir="/work"
else
  case "$current" in
    "$repo"/*) guest_dir="/work/${current#"$repo"/}" ;;
    *) guest_dir="/work" ;;
  esac
fi

uid="$(id -u)"
data_root="${XDG_DATA_HOME:-$HOME/.local/share}/devvm"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/devvm"
runtime_parent="${XDG_RUNTIME_DIR:-/tmp}/devvm-$uid"
base_image="$cache_root/debian-13-generic-amd64.qcow2"
golden="$data_root/base-v${BASE_VERSION}.qcow2"
seed_image="$data_root/seed-v${BASE_VERSION}.img"
ssh_dir="$data_root/ssh"
ssh_key="$ssh_dir/id_ed25519"
claude_state="$data_root/claude"
codex_state="$data_root/codex"
lock_file="$data_root/base.lock"

mkdir -p "$data_root" "$cache_root" "$runtime_parent" "$ssh_dir" "$claude_state" "$codex_state"
chmod 700 "$data_root" "$ssh_dir" "$claude_state" "$codex_state"

if [ "$refresh" -eq 1 ]; then
  log "refreshing disposable VM base"
  rm -f "$golden" "$seed_image"
fi

seed_existing_auth() {
  if [ ! -e "$claude_state/.credentials.json" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
    cp "$HOME/.claude/.credentials.json" "$claude_state/.credentials.json"
    chmod 600 "$claude_state/.credentials.json"
    log "seeded Claude login from host"
  fi
  if [ ! -e "$codex_state/auth.json" ] && [ -f "$HOME/.codex/auth.json" ]; then
    cp "$HOME/.codex/auth.json" "$codex_state/auth.json"
    chmod 600 "$codex_state/auth.json"
    log "seeded Codex login from host"
  fi
}
seed_existing_auth

ensure_ssh_key() {
  if [ ! -f "$ssh_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
    chmod 600 "$ssh_key"
  fi
}

ensure_debian_image() {
  [ -f "$base_image" ] && return 0

  log "downloading Debian 13 base image (one-time)"
  sums="$cache_root/SHA512SUMS.tmp"
  part="$base_image.part"
  rm -f "$sums" "$part"
  curl -fL --retry 3 --retry-delay 1 "$DEBIAN_SUMS_URL" -o "$sums"
  expected="$(awk '$2 == "debian-13-generic-amd64.qcow2" { print $1; exit }' "$sums")"
  [ -n "$expected" ] || die "could not find Debian image checksum"
  curl -fL --retry 3 --retry-delay 1 "$DEBIAN_URL" -o "$part"
  actual="$(sha512sum "$part" | awk '{ print $1 }')"
  [ "$actual" = "$expected" ] || { rm -f "$part"; die "Debian image checksum mismatch"; }
  mv "$part" "$base_image"
  rm -f "$sums"
}

choose_port() {
  local port
  local _attempt
  for _attempt in $(seq 1 100); do
    port=$((20000 + RANDOM % 30000))
    if ! ss -ltnH | awk '{print $4}' | grep -qE "(^|:)${port}$"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

virtio_pids=()
qemu_pid=""
run_dir=""

cleanup() {
  local pid
  if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$qemu_pid" 2>/dev/null || true
  fi
  for pid in "${virtio_pids[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  [ -n "$run_dir" ] && rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

start_share() {
  local tag="$1"
  local path="$2"
  local sock="$run_dir/${tag}.sock"
  local log_file="$run_dir/${tag}.log"
  local pid

  rm -f "$sock"
  virtiofsd --socket-path="$sock" --shared-dir="$path" --log-level=warn >"$log_file" 2>&1 &
  pid=$!
  virtio_pids+=("$pid")

  for _ in $(seq 1 100); do
    [ -S "$sock" ] && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$log_file" >&2 || true
      die "virtiofsd failed for $tag"
    fi
    sleep 0.02
  done
  die "timed out starting virtiofsd for $tag"
}

qemu_common_args() {
  local disk="$1"
  local port="$2"
  printf '%s\0' \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "$VM_CPUS" \
    -m "$VM_RAM_MB" \
    -object "memory-backend-memfd,id=mem,size=${VM_RAM_MB}M,share=on" \
    -numa node,memdev=mem \
    -drive "if=virtio,format=qcow2,file=$disk" \
    -drive "if=virtio,format=raw,file=$seed_image,readonly=on" \
    -device virtio-rng-pci \
    -chardev "socket,id=repo,path=$run_dir/repo.sock" \
    -device vhost-user-fs-pci,chardev=repo,tag=repo \
    -chardev "socket,id=claude,path=$run_dir/claude.sock" \
    -device vhost-user-fs-pci,chardev=claude,tag=claude \
    -chardev "socket,id=codex,path=$run_dir/codex.sock" \
    -device vhost-user-fs-pci,chardev=codex,tag=codex \
    -netdev "user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:${port}-:22" \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial none \
    -monitor none \
    -no-reboot
}

ssh_base_args=()
make_ssh_args() {
  local port="$1"
  ssh_base_args=(
    -p "$port"
    -i "$ssh_key"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o ConnectTimeout=1
    -o ConnectionAttempts=1
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=3
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
  )
}

wait_for_ssh() {
  local port="$1"
  make_ssh_args "$port"
  for _ in $(seq 1 240); do
    if ssh "${ssh_base_args[@]}" dev@127.0.0.1 true 2>/dev/null; then
      return 0
    fi
    [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

write_cloud_init() {
  local pubkey
  local user_data="$run_dir/user-data"
  local meta_data="$run_dir/meta-data"
  pubkey="$(cat "$ssh_key.pub")"

  cat >"$meta_data" <<EOF_META
instance-id: dev-base-v${BASE_VERSION}
local-hostname: devvm
EOF_META

  cat >"$user_data" <<EOF_HEAD
#cloud-config
preserve_hostname: false
hostname: devvm
manage_etc_hosts: true
disable_root: true
ssh_pwauth: false
package_update: true
package_upgrade: false
users:
  - name: dev
    uid: $uid
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys:
      - $pubkey
packages:
  - openssh-server
  - nftables
  - sudo
  - git
  - curl
  - ca-certificates
  - build-essential
  - clang
  - cmake
  - pkg-config
  - python3
  - python3-pip
  - python3-venv
  - nodejs
  - npm
  - rustc
  - cargo
  - ripgrep
  - fd-find
  - jq
  - unzip
  - zip
  - less
  - tmux
  - shellcheck
  - sqlite3
  - libssl-dev
  - libffi-dev
  - libsqlite3-dev
write_files:
  - path: /etc/profile.d/dev.sh
    permissions: '0644'
    content: |
EOF_HEAD

  cat >>"$user_data" <<'EOF_PROMPT'
      export PATH="$HOME/.local/npm/bin:$HOME/.local/bin:$PATH"
      export DEVVM=1
      if [[ $- == *i* ]]; then
        dev_prompt() {
          local rc="$?"
          local repo="${DEVVM_REPO:-work}"
          local branch=""
          local place="${PWD#/work}"
          local arrow_color="32"
          [ -n "$place" ] || place="/"
          if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true)"
          fi
          [ "$rc" -eq 0 ] || arrow_color="31"
          PS1="\[\e[1;35m\]◆ dev\[\e[0m\] · \[\e[1;36m\]${repo}\[\e[0m\]"
          [ -z "$branch" ] || PS1+=" · \[\e[1;33m\]${branch}\[\e[0m\]"
          [ "$place" = "/" ] || PS1+=" · \[\e[2m\]${place}\[\e[0m\]"
          PS1+=" \[\e[1;${arrow_color}m\]❯\[\e[0m\] "
          printf '\033]0;DEV — %s\007' "$repo"
        }
        PROMPT_COMMAND=dev_prompt
      fi
EOF_PROMPT

  cat >>"$user_data" <<'EOF_FIREWALL'
  - path: /etc/nftables.conf
    permissions: '0644'
    content: |
      table inet devvm {
        chain output {
          type filter hook output priority 0; policy accept;
          ct state established,related accept
          ip daddr 10.0.2.3 udp dport 53 accept
          ip daddr 10.0.2.3 tcp dport 53 accept
          ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16 } reject
        }
      }
EOF_FIREWALL

  cat >>"$user_data" <<'EOF_TAIL'
runcmd:
  - [ bash, -lc, 'mkdir -p /work /mnt/devstate/claude /mnt/devstate/codex /home/dev/.claude /home/dev/.codex /home/dev/.local/npm' ]
  - [ bash, -lc, 'mount -t virtiofs repo /work' ]
  - [ bash, -lc, 'mount -t virtiofs claude /mnt/devstate/claude' ]
  - [ bash, -lc, 'mount -t virtiofs codex /mnt/devstate/codex' ]
  - [ bash, -lc, 'printf "repo /work virtiofs rw,nofail 0 0\nclaude /mnt/devstate/claude virtiofs rw,nofail 0 0\ncodex /mnt/devstate/codex virtiofs rw,nofail 0 0\n" >> /etc/fstab' ]
  - [ bash, -lc, 'chown -R dev:dev /home/dev/.local /home/dev/.claude /home/dev/.codex' ]
  - [ bash, -lc, 'sudo -u dev -H npm config set prefix /home/dev/.local/npm' ]
  - [ bash, -lc, 'sudo -u dev -H npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest' ]
  - [ bash, -lc, 'ln -sf /usr/bin/fdfind /usr/local/bin/fd' ]
  - [ bash, -lc, 'systemctl enable --now nftables' ]
  - [ bash, -lc, 'systemctl enable --now ssh' ]
  - [ bash, -lc, 'touch /var/lib/devvm-ready' ]
EOF_TAIL

  cloud-localds "$seed_image" "$user_data" "$meta_data"
}

prepare_base() {
  ensure_ssh_key
  ensure_debian_image

  exec 9>"$lock_file"
  flock 9
  [ -f "$golden" ] && [ -f "$seed_image" ] && return 0

  log "preparing Debian dev image (first run only)"
  rm -f "$golden" "$seed_image"
  qemu-img create -q -f qcow2 -F qcow2 -b "$base_image" "$golden" 64G

  run_dir="$(mktemp -d "$runtime_parent/bootstrap.XXXXXX")"
  write_cloud_init
  start_share repo "$repo"
  start_share claude "$claude_state"
  start_share codex "$codex_state"
  port="$(choose_port)" || die "could not find a free localhost port"

  mapfile -d '' qargs < <(qemu_common_args "$golden" "$port")
  qemu-system-x86_64 "${qargs[@]}" >"$run_dir/qemu.log" 2>&1 &
  qemu_pid=$!

  if ! wait_for_ssh "$port"; then
    cat "$run_dir/qemu.log" >&2 || true
    rm -f "$golden" "$seed_image"
    die "VM did not become reachable during base setup"
  fi

  log "installing dev tools and Claude/Codex"
  if ! ssh "${ssh_base_args[@]}" dev@127.0.0.1 'sudo cloud-init status --wait >/dev/null && test -f /var/lib/devvm-ready'; then
    ssh "${ssh_base_args[@]}" dev@127.0.0.1 'sudo tail -n 100 /var/log/cloud-init-output.log' >&2 || true
    rm -f "$golden" "$seed_image"
    die "base provisioning failed"
  fi

  ssh "${ssh_base_args[@]}" dev@127.0.0.1 'sudo poweroff' >/dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
  fi
  qemu_pid=""
  for pid in "${virtio_pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  virtio_pids=()
  rm -rf "$run_dir"
  run_dir=""
  log "base ready"
}

prepare_base

run_dir="$(mktemp -d "$runtime_parent/session.XXXXXX")"
start_share repo "$repo"
start_share claude "$claude_state"
start_share codex "$codex_state"
port="$(choose_port)" || die "could not find a free localhost port"

mapfile -d '' qargs < <(qemu_common_args "$golden" "$port")
qemu-system-x86_64 "${qargs[@]}" -snapshot >"$run_dir/qemu.log" 2>&1 &
qemu_pid=$!

if ! wait_for_ssh "$port"; then
  cat "$run_dir/qemu.log" >&2 || true
  die "VM did not become reachable"
fi

# Agent runtime state stays on the VM's native filesystem. Only credential
# files are copied to/from the persistent host-backed shares.
ssh "${ssh_base_args[@]}" dev@127.0.0.1 'mkdir -p "$HOME/.claude" "$HOME/.codex"; [ ! -f /mnt/devstate/claude/.credentials.json ] || cp /mnt/devstate/claude/.credentials.json "$HOME/.claude/.credentials.json"; [ ! -f /mnt/devstate/codex/auth.json ] || cp /mnt/devstate/codex/auth.json "$HOME/.codex/auth.json"; chmod 600 "$HOME/.claude/.credentials.json" "$HOME/.codex/auth.json" 2>/dev/null || true'

log "$repo_name → $guest_dir"
quoted_dir="$(printf '%q' "$guest_dir")"
quoted_repo="$(printf '%q' "$repo_name")"
if [ "${#command_args[@]}" -eq 0 ]; then
  remote="cd $quoted_dir && export DEVVM_REPO=$quoted_repo && exec bash -l"
else
  printf -v quoted_cmd '%q ' "${command_args[@]}"
  remote="cd $quoted_dir && export DEVVM_REPO=$quoted_repo && export PATH=\$HOME/.local/npm/bin:\$HOME/.local/bin:\$PATH && exec $quoted_cmd"
fi

set +e
ssh -tt "${ssh_base_args[@]}" dev@127.0.0.1 "$remote"
rc=$?
set -e

ssh "${ssh_base_args[@]}" dev@127.0.0.1 'mkdir -p /mnt/devstate/claude /mnt/devstate/codex; [ ! -f "$HOME/.claude/.credentials.json" ] || cp "$HOME/.claude/.credentials.json" /mnt/devstate/claude/.credentials.json; [ ! -f "$HOME/.codex/auth.json" ] || cp "$HOME/.codex/auth.json" /mnt/devstate/codex/auth.json' >/dev/null 2>&1 || true
ssh "${ssh_base_args[@]}" dev@127.0.0.1 'sudo poweroff' >/dev/null 2>&1 || true
exit "$rc"
