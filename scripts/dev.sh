#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: dev [--help] [command ...]

Run the current git repository inside a disposable NixOS MicroVM.

  dev                    enter an interactive shell
  dev claude [args...]   run Claude Code
  dev codex [args...]    run Codex
  dev <command ...>      run any command in the VM

Guest services listening on TCP ports >= 1024 are automatically forwarded to
the same localhost port on the host when that port is available.
USAGE
}

log() { printf '\033[1;35m◆ dev\033[0m %s\n' "$*"; }
die() { printf 'dev: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

[ -n "${DEV_RUNNER:-}" ] || die "runner configuration is missing; rebuild NixOS"

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

command_args=("$@")
uid="$(id -u)"
gid="$(id -g)"
data_root="${XDG_DATA_HOME:-$HOME/.local/share}/dev"
runtime_root="${XDG_RUNTIME_DIR:-/tmp}/dev-$uid"
repo_hash="$(printf '%s' "$repo" | sha256sum | awk '{print substr($1,1,16)}')"
state_dir="$data_root/projects/${repo_name}-${repo_hash}"
ssh_root="$data_root/ssh"
ssh_key="$ssh_root/id_ed25519"
control_socket="$runtime_root/ssh-${repo_hash}.sock"

mkdir -p "$state_dir" "$runtime_root" "$ssh_root" "$state_dir/ssh"
chmod 700 "$data_root" "$runtime_root" "$ssh_root" "$state_dir" "$state_dir/ssh"

if [ ! -f "$ssh_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$ssh_key"
  chmod 600 "$ssh_key"
fi
cp "$ssh_key.pub" "$state_dir/ssh/authorized_keys"
chmod 600 "$state_dir/ssh/authorized_keys"
ln -sfn "$repo" "$state_dir/repo"

# One persistent state disk per repository. Parallel work on the same checkout
# is deliberately rejected; use a git worktree when you want two agents editing
# the same project concurrently.
exec {state_lock_fd}>"$state_dir/instance.lock"
if ! flock -n "$state_lock_fd"; then
  die "a dev VM for this repo is already running; use a git worktree for parallel work"
fi

choose_port() {
  local port
  for _ in $(seq 1 100); do
    port=$((20000 + RANDOM % 30000))
    if ! ss -ltnH | awk -v p="$port" '{ a=$4; sub(/^.*:/, "", a); if (a == p) found=1 } END { exit !found }'; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  return 1
}

ssh_port="$(choose_port)" || die "could not find a free localhost SSH port"
ssh_target="dev@127.0.0.1"
repo_socket="$state_dir/dev-virtiofs-repo.sock"
virtiofs_pid=""
vm_pid=""
watcher_pid=""
ports_log="$state_dir/ports.log"
vm_log="$state_dir/vm.log"
virtiofs_log="$state_dir/virtiofs.log"

ssh_opts=(
  -p "$ssh_port"
  -i "$ssh_key"
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=1
  -o ConnectionAttempts=1
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

ssh_once() {
  ssh "${ssh_opts[@]}" "$ssh_target" "$@"
}

ssh_dev() {
  if [ -S "$control_socket" ]; then
    ssh -S "$control_socket" "${ssh_opts[@]}" "$ssh_target" "$@"
  else
    ssh_once "$@"
  fi
}

stop_vm() {
  if [ -n "$vm_pid" ] && kill -0 "$vm_pid" 2>/dev/null; then
    ssh_dev 'sudo poweroff' </dev/null >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      kill -0 "$vm_pid" 2>/dev/null || return 0
      sleep 0.05
    done
    kill "$vm_pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$vm_pid" 2>/dev/null || return 0
      sleep 0.05
    done
    kill -9 "$vm_pid" 2>/dev/null || true
  fi
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$watcher_pid" ]; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi
  if [ -S "$control_socket" ]; then
    ssh -S "$control_socket" -O exit "${ssh_opts[@]}" "$ssh_target" >/dev/null 2>&1 || true
  fi
  stop_vm
  if [ -n "$virtiofs_pid" ]; then
    kill "$virtiofs_pid" 2>/dev/null || true
    wait "$virtiofs_pid" 2>/dev/null || true
  fi
  rm -f "$state_dir/nix-rw.img" "$repo_socket" "$control_socket"
  find "$state_dir" -maxdepth 1 -type s -delete 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

# The writable Nix store is intentionally disposable. Persistent state is only
# the agent state volume and the repository itself.
rm -f "$state_dir/nix-rw.img" "$repo_socket" "$control_socket"
find "$state_dir" -maxdepth 1 -type s -delete 2>/dev/null || true
: >"$vm_log"
: >"$virtiofs_log"

# Rootless virtiofsd maps guest UID/GID 1000 to the invoking host user. This
# gives native-ish workspace performance without granting the daemon root or
# changing ownership of files in the checkout.
virtiofsd \
  --socket-path="$repo_socket" \
  --shared-dir="$repo" \
  --sandbox=namespace \
  --uid-map ":0:${uid}:1:" \
  --gid-map ":0:${gid}:1:" \
  --translate-uid "map:1000:0:1" \
  --translate-gid "map:1000:0:1" \
  --xattr \
  >"$virtiofs_log" 2>&1 &
virtiofs_pid=$!

for _ in $(seq 1 100); do
  [ -S "$repo_socket" ] && break
  if ! kill -0 "$virtiofs_pid" 2>/dev/null; then
    cat "$virtiofs_log" >&2 || true
    die "virtiofsd failed to start"
  fi
  sleep 0.02
done
[ -S "$repo_socket" ] || die "timed out waiting for virtiofsd"

(
  cd "$state_dir"
  export DEV_SSH_PORT="$ssh_port"
  exec "$DEV_RUNNER/bin/microvm-run"
) >"$vm_log" 2>&1 &
vm_pid=$!

wait_for_vm() {
  for _ in $(seq 1 200); do
    if ! kill -0 "$vm_pid" 2>/dev/null; then
      return 1
    fi
    if ssh_once 'test -e /run/dev-ready' </dev/null >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

if ! wait_for_vm; then
  cat "$vm_log" >&2 || true
  die "MicroVM did not become ready"
fi

# Reuse one SSH transport for the shell, port watcher, and forwarded dev-server
# ports. This makes the background port discovery cheap.
ssh "${ssh_opts[@]}" \
  -M -N -f \
  -o ControlMaster=yes \
  -o ControlPath="$control_socket" \
  -o ControlPersist=no \
  "$ssh_target"

seed_auth_file() {
  local host_file="$1"
  local remote_file="$2"
  [ -f "$host_file" ] || return 0
  if ! ssh_dev "test -e '$remote_file'" </dev/null >/dev/null 2>&1; then
    ssh_dev "umask 077; cat > '$remote_file'" <"$host_file" >/dev/null
  fi
}

seed_auth_file "$HOME/.claude/.credentials.json" '/home/dev/.claude/.credentials.json'
seed_auth_file "$HOME/.codex/auth.json" '/home/dev/.codex/auth.json'

host_port_busy() {
  local port="$1"
  ss -ltnH | awk -v p="$port" '
    {
      a=$4
      sub(/^.*:/, "", a)
      if (a == p) found=1
    }
    END { exit !found }
  '
}

watch_ports() {
  local ports port
  : >"$ports_log"
  while kill -0 "$vm_pid" 2>/dev/null; do
    ports="$(ssh_dev "ss -ltnH | awk '{ a=\$4; sub(/^.*:/, \"\", a); if (a ~ /^[0-9]+\$/ && a >= 1024) print a }' | sort -nu" </dev/null 2>/dev/null || true)"
    while IFS= read -r port; do
      [ -n "$port" ] || continue
      grep -qx "$port" "$ports_log" 2>/dev/null && continue
      host_port_busy "$port" && continue
      if ssh -S "$control_socket" -O forward \
        -L "127.0.0.1:${port}:localhost:${port}" \
        "${ssh_opts[@]}" "$ssh_target" >/dev/null 2>&1; then
        printf '%s\n' "$port" >>"$ports_log"
      fi
    done <<<"$ports"
    sleep 1
  done
}

if [ "${DEV_NO_AUTO_FORWARD:-0}" != "1" ]; then
  watch_ports &
  watcher_pid=$!
fi

log "$repo_name → $guest_dir"
quoted_dir="$(printf '%q' "$guest_dir")"
quoted_repo="$(printf '%q' "$repo_name")"

if [ "${#command_args[@]}" -eq 0 ]; then
  remote="cd $quoted_dir && export DEV_REPO=$quoted_repo && exec bash -l"
else
  printf -v quoted_cmd '%q ' "${command_args[@]}"
  shell_command="exec ${quoted_cmd% }"
  quoted_shell_command="$(printf '%q' "$shell_command")"
  remote="cd $quoted_dir && export DEV_REPO=$quoted_repo && exec bash -lc $quoted_shell_command"
fi

set +e
ssh -tt -S "$control_socket" "${ssh_opts[@]}" "$ssh_target" "$remote"
rc=$?
set -e

exit "$rc"
