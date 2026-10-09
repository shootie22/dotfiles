#!/usr/bin/env bash
# Launcher for development MicroVMs. See README.md next to this file.
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: dev [--nonet] [command ...]
       dev allow [--ro] [--global] PATH ...
       dev deny [--global] PATH ...
       dev allowed | dev stop

Run this folder (its git root, if inside a repository) in a disposable NixOS
MicroVM, mounted at the same path. Nothing else on the host is visible.

  dev                    shell in the VM
  dev <command ...>      run a command (dev claude, dev npm run dev, ...)
  dev --nonet [...]      VM without a network device
  dev allow [--ro] PATH  also mount PATH in this project's VM from now on
                         (--global: in every project's VM)
  dev deny PATH          remove a grant
  dev allowed            list grants that apply here
  dev stop               stop this folder's VM (disconnects all sessions)

Running dev again in the same folder joins the running VM; it stops 5
minutes after the last session exits (DEV_LINGER=<seconds> to change). Guest TCP ports >= 1024 are forwarded to the same
port on the host's localhost while it is free.

Files: ~/.config/dev/env   KEY=VALUE pairs exported in the VM (agent tokens)
       ~/.config/dev/allow grants (tab-separated: project, rw|ro, path)
USAGE
}

log() { printf '\033[1;35m◆ dev\033[0m %s\n' "$*" >&2; }
die() { printf 'dev: %s\n' "$*" >&2; exit 1; }

[ -n "${DEV_RUNNER:-}" ] || die "runner configuration is missing; rebuild NixOS"

uid="$(id -u)"
gid="$(id -g)"
home="$(realpath "$HOME")"
config_dir="${XDG_CONFIG_HOME:-$home/.config}/dev"
allow_file="$config_dir/allow"
env_file="$config_dir/env"
data_root="${XDG_DATA_HOME:-$home/.local/share}/dev"
runtime_root="${XDG_RUNTIME_DIR:-/tmp/dev-$uid}/dev"
ssh_key="$data_root/ssh/id_ed25519"

mkdir -p "$config_dir" "$data_root/ssh" "$runtime_root"
chmod 700 "$config_dir" "$data_root" "$data_root/ssh" "$runtime_root"
config_dir="$(realpath "$config_dir")"

# Refuse anything whose sharing would expose the whole home directory, or
# dev's own configuration (which would let a VM grant itself more access).
check_shareable() {
  local p="$1"
  [ "$p" != / ] || die "refusing to share /"
  case "$home/" in "$p"/*) die "refusing to share $p: it contains your home directory" ;; esac
  case "$p/" in "$config_dir"/*) die "refusing to share $p: it is dev's configuration" ;; esac
  case "$config_dir/" in "$p"/*) die "refusing to share $p: it contains $config_dir" ;; esac
}

resolve_project() {
  local top
  if top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)"; then
    realpath "$top"
  else
    realpath "$PWD"
  fi
}

# Sets id, state, rt, cid for a project directory.
project_paths() {
  local hash name
  hash="$(printf '%s' "$1" | sha256sum | cut -c1-16)"
  name="$(basename "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-32)"
  id="$name-$hash"
  state="$data_root/$id"
  rt="$runtime_root/$id"
  # One VM per project, so a CID derived from the project path is unique.
  cid=$((0x${hash:0:7} + 3))
}

# Grants applying to a project: "<rw|ro>\t<path>" lines, project-specific
# ones taking precedence over --global ones for the same path.
grants_for() {
  [ -f "$allow_file" ] || return 0
  awk -F '\t' -v p="$1" '
    $1 == p   { mode[$3] = $2; seen[$3] = 1 }
    $1 == "*" { if (!seen[$3]) mode[$3] = $2 }
    END { for (path in mode) print mode[path] "\t" path }
  ' "$allow_file" | sort -t $'\t' -k2
}

# Everything a VM is launched with, to detect a running VM that is stale.
launch_config() {
  printf 'net=%s\n' "$2"
  grants_for "$1"
  [ ! -f "$env_file" ] || sha256sum <"$env_file"
}

cmd_allow() {
  local project="$1" mode=rw scope path; shift
  scope="$project"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ro) mode=ro; shift ;;
      --rw) mode=rw; shift ;;
      --global) scope='*'; shift ;;
      -*) die "allow: unknown option $1" ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || die "usage: dev allow [--ro] [--global] PATH ..."
  touch "$allow_file"
  chmod 600 "$allow_file"
  for path in "$@"; do
    path="$(realpath -e "$path" 2>/dev/null)" || die "no such directory: $path"
    [ -d "$path" ] || die "not a directory: $path (only folders can be shared)"
    check_shareable "$path"
    case "$path/" in "$project"/*) die "$path is already inside the project" ;; esac
    awk -F '\t' -v s="$scope" -v p="$path" '!($1 == s && $3 == p)' "$allow_file" >"$allow_file.tmp"
    printf '%s\t%s\t%s\n' "$scope" "$mode" "$path" >>"$allow_file.tmp"
    mv "$allow_file.tmp" "$allow_file"
    if [ "$scope" = '*' ]; then
      log "allowed $path ($mode) in every project"
    else
      log "allowed $path ($mode)"
    fi
  done
}

cmd_deny() {
  local project="$1" scope path; shift
  scope="$project"
  if [ "${1:-}" = --global ]; then scope='*'; shift; fi
  [ $# -gt 0 ] || die "usage: dev deny [--global] PATH ..."
  [ -f "$allow_file" ] || return 0
  for path in "$@"; do
    path="$(realpath -m "$path")"
    awk -F '\t' -v s="$scope" -v p="$path" '!($1 == s && $3 == p)' "$allow_file" >"$allow_file.tmp"
    mv "$allow_file.tmp" "$allow_file"
    log "removed $path"
  done
}

# --- the VM supervisor ------------------------------------------------------
# Runs detached. Boots the VM, then waits until no session holds the shared
# lock on sessions.lock, and shuts everything down.

ssh_opts() {
  ssh_args=(
    -l dev
    -i "$ssh_key"
    -o "ProxyCommand=socat - VSOCK-CONNECT:$cid:22"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ControlPath="$rt/ssh.sock"
  )
}

supervise() {
  local project="$1" net="$2"
  project_paths "$project"
  ssh_opts

  # Globals, not locals: cleanup runs from the EXIT trap after this returns.
  vm_pid="" watcher_pid="" fs_pids=()
  local shares=() mounts="" protect="" i=0
  local mode path common gitdir

  cleanup() {
    trap - EXIT INT TERM HUP
    rm -f "$rt/ready"
    [ -z "$watcher_pid" ] || kill "$watcher_pid" 2>/dev/null || true
    ssh -O exit "${ssh_args[@]}" dev >/dev/null 2>&1 || true
    if [ -n "$vm_pid" ] && kill -0 "$vm_pid" 2>/dev/null; then
      printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"system_powerdown"}' |
        socat -t 1 - UNIX-CONNECT:"$state/control.sock" >/dev/null 2>&1 || true
      for _ in $(seq 1 100); do kill -0 "$vm_pid" 2>/dev/null || break; sleep 0.1; done
      kill "$vm_pid" 2>/dev/null || true
      wait "$vm_pid" 2>/dev/null || true
    fi
    for pid in "${fs_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$state/host" "$state/nix-rw.img" "$state"/*.sock "$rt/ssh.sock" "$rt/supervisor.pid"
  }
  trap cleanup EXIT
  trap 'exit 0' INT TERM HUP

  echo $$ >"$rt/supervisor.pid"
  printf '%s\n' "$net" >"$rt/net"
  launch_config "$project" "$net" >"$rt/config"
  cd "$state"
  rm -rf host nix-rw.img ./*.sock

  # Shares: the project, granted folders, and the git directory of a worktree
  # whose repository lives elsewhere.
  shares+=("rw"$'\t'"$project")
  while IFS=$'\t' read -r mode path; do
    [ -n "$path" ] || continue
    if [ ! -d "$path" ]; then log "skipping missing grant $path"; continue; fi
    (check_shareable "$path") || continue
    shares+=("$mode"$'\t'"$path")
  done < <(grants_for "$project")

  # Git runs hooks and config-defined commands (core.fsmonitor, filters) on
  # the host. The guest gets those files read-only, and the hooks directory
  # must exist so the guest cannot create one.
  if common="$(git -C "$project" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    gitdir="$(git -C "$project" rev-parse --path-format=absolute --git-dir)"
    mkdir -p "$common/hooks"
    protect+="$common/config"$'\n'"$common/hooks"$'\n'
    [ ! -e "$gitdir/config.worktree" ] || protect+="$gitdir/config.worktree"$'\n'
    case "$common/" in "$project"/*) ;; *) shares+=("rw"$'\t'"$common") ;; esac
  fi

  # The guest sees this 9p share as root-owned, so it must be world-readable
  # for the dev user (sshd reads authorized_keys as dev). The state directory
  # itself is 0700 on the host.
  mkdir -m 755 host
  cp "$ssh_key.pub" host/authorized_keys
  printf '%s' "$protect" >host/protect
  if [ -f "$env_file" ]; then
    install -m 644 "$env_file" host/env
  fi
  {
    printf '[user]\n'
    printf '\tname = %s\n' "$(git config --global --get user.name || true)"
    printf '\temail = %s\n' "$(git config --global --get user.email || true)"
    printf '[init]\n\tdefaultBranch = main\n'
  } >host/gitconfig

  # Rootless virtiofsd: guest uid/gid 1000 maps to the invoking user, so files
  # keep their host ownership. Anything else on the host shows as nobody.
  # The store is immutable, so its daemon can cache aggressively; shares the
  # host also edits keep the default coherent caching.
  start_virtiofsd() {
    local socket="$1" dir="$2" ro="$3" cache="${4:-auto}"
    virtiofsd \
      --socket-path="$socket" \
      --shared-dir="$dir" \
      --sandbox=namespace \
      --uid-map ":0:${uid}:1:" \
      --gid-map ":0:${gid}:1:" \
      --translate-uid "map:1000:0:1" \
      --translate-gid "map:1000:0:1" \
      --xattr \
      --cache="$cache" \
      ${ro:+--readonly} \
      >>"$state/virtiofs.log" 2>&1 &
    fs_pids+=($!)
  }

  : >"$state/virtiofs.log"
  start_virtiofsd dev-virtiofs-ro-store.sock /nix/store ro always
  local tags=()
  for entry in "${shares[@]}"; do
    mode="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    if [ "$mode" = ro ]; then
      start_virtiofsd "d$i.sock" "$path" ro
    else
      start_virtiofsd "d$i.sock" "$path" ""
    fi
    tags+=("d$i")
    mounts+="d$i"$'\t'"$mode"$'\t'"$path"$'\n'
    i=$((i + 1))
  done
  printf '%s' "$mounts" >host/mounts

  for sock in dev-virtiofs-ro-store.sock "${tags[@]/%/.sock}"; do
    for _ in $(seq 1 100); do [ -S "$sock" ] && break; sleep 0.02; done
    [ -S "$sock" ] || die "virtiofsd did not start (see $state/virtiofs.log)"
  done

  (
    export DEV_CID="$cid" DEV_NET="$net" DEV_SHARES="${tags[*]}"
    exec "$DEV_RUNNER/bin/microvm-run"
  ) </dev/null >"$state/vm.log" 2>&1 &
  vm_pid=$!

  local up=0
  for _ in $(seq 1 600); do
    kill -0 "$vm_pid" 2>/dev/null || break
    if ssh "${ssh_args[@]}" -o ConnectTimeout=2 dev 'test -e /run/dev-ready' </dev/null >/dev/null 2>&1; then
      up=1
      break
    fi
    sleep 0.1
  done
  [ "$up" = 1 ] || die "the VM did not become ready (see $state/vm.log)"

  ssh "${ssh_args[@]}" -M -N -f -o ControlMaster=yes -o ControlPersist=no dev

  watch_ports() {
    local ports port forwarded=" "
    while kill -0 "$vm_pid" 2>/dev/null; do
      ports="$(ssh "${ssh_args[@]}" dev \
        "ss -ltnH | awk '{ a=\$4; sub(/^.*:/, \"\", a); if (a ~ /^[0-9]+\$/ && a >= 1024) print a }' | sort -nu" \
        </dev/null 2>/dev/null || true)"
      for port in $ports; do
        case "$forwarded" in *" $port "*) continue ;; esac
        if ss -ltnH "sport = :$port" | grep -q .; then continue; fi
        if ssh -O forward -L "127.0.0.1:$port:localhost:$port" "${ssh_args[@]}" dev >/dev/null 2>&1; then
          forwarded+="$port "
          printf 'localhost:%s\n' "$port" >>"$rt/ports"
        fi
      done
      sleep 1
    done
  }
  : >"$rt/ports"
  watch_ports &
  watcher_pid=$!

  touch "$rt/ready"

  # Stay up for DEV_LINGER seconds after the last session leaves, so the next
  # `dev <cmd>` connects instantly instead of booting.
  local linger="${DEV_LINGER:-300}" idle_since=""
  exec 8>"$rt/sessions.lock"
  while kill -0 "$vm_pid" 2>/dev/null; do
    if flock -n -x 8; then
      idle_since="${idle_since:-$SECONDS}"
      if [ $((SECONDS - idle_since)) -ge "$linger" ]; then
        break
      fi
      flock -u 8
    else
      idle_since=""
    fi
    sleep 0.5
  done
  # cleanup runs with the exclusive lock held, so a new session waits for the
  # shutdown to finish and then boots a fresh VM.
}

# --- argument parsing ---------------------------------------------------------

net=1
explicit=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --nonet) net=0; shift ;;
    --) explicit=1; shift; break ;;
    *) break ;;
  esac
done

if [ "${1:-}" = __supervise ]; then
  shift
  supervise "$@"
  exit 0
fi

project="$(resolve_project)"
check_shareable "$project"

if [ "$explicit" = 0 ]; then
  case "${1:-}" in
    allow) shift; cmd_allow "$project" "$@"; exit 0 ;;
    deny) shift; cmd_deny "$project" "$@"; exit 0 ;;
    allowed)
      grants_for "$project" | awk -F '\t' '{ printf "%s  %s\n", $1, $2 }'
      exit 0
      ;;
    stop)
      project_paths "$project"
      if [ -f "$rt/supervisor.pid" ] && kill "$(cat "$rt/supervisor.pid")" 2>/dev/null; then
        log "stopping"
      else
        log "no VM running for $project"
      fi
      exit 0
      ;;
  esac
fi

# --- session ----------------------------------------------------------------

project_paths "$project"
mkdir -p "$state" "$rt"
chmod 700 "$state" "$rt"
ssh_opts

if [ ! -f "$ssh_key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C dev -f "$ssh_key"
fi

# The shared lock marks this session as alive. This shell holds it until ssh
# exits (ssh closes inherited fds, so it cannot hold it itself). Taking it
# blocks while a previous VM is shutting down.
exec 8>"$rt/sessions.lock"
flock -s 8

exec 7>"$rt/boot.lock"
flock -x 7

vm_running() {
  [ -e "$rt/ready" ] && kill -0 "$(cat "$rt/supervisor.pid" 2>/dev/null)" 2>/dev/null
}

# The running VM was started with a different network mode, grants or env
# file. If nobody else is using it (it is only lingering), restart it.
wanted_config="$(launch_config "$project" "$net")"
if vm_running && [ "$wanted_config" != "$(cat "$rt/config" 2>/dev/null)" ]; then
  idle=0
  for _ in 1 2 3; do
    # Upgrading our shared lock succeeds only if no other session holds one.
    if flock -n -x 8; then idle=1; break; fi
    sleep 0.2
  done
  if [ "$idle" = 1 ]; then
    old_pid="$(cat "$rt/supervisor.pid")"
    kill "$old_pid" 2>/dev/null || true
    while kill -0 "$old_pid" 2>/dev/null; do sleep 0.1; done
    flock -s 8
  elif [ "$(cat "$rt/net")" != "$net" ]; then
    if [ "$net" = 0 ]; then
      die "this folder's VM is in use with network; exit its other sessions (or dev stop) first"
    fi
    die "this folder's VM is in use without network; exit its other sessions (or dev stop) first"
  else
    log "grants or env changed; they apply once this folder's other sessions exit"
  fi
fi

if vm_running; then
  :
else
  # QEMU would otherwise boot with a silently dead network device.
  if [ "$net" = 1 ] && [ ! -S /run/dev-net/passt.sock ]; then
    die "the network backend (/run/dev-net/passt.sock) is missing; switch to the NixOS config with modules.dev, or use --nonet"
  fi
  rm -f "$rt/ready"
  setsid bash "${BASH_SOURCE[0]}" __supervise "$project" "$net" \
    </dev/null >"$state/supervisor.log" 2>&1 7>&- 8>&- &
  sup_pid=$!
  start=$SECONDS
  until [ -e "$rt/ready" ]; do
    if ! kill -0 "$sup_pid" 2>/dev/null; then
      cat "$state/supervisor.log" >&2 || true
      echo "--- last lines of $state/vm.log:" >&2
      tail -n 30 "$state/vm.log" >&2 || true
      die "failed to start the VM"
    fi
    sleep 0.05
  done
  [ -z "${DEV_TIMING:-}" ] || log "ready in $((SECONDS - start))s"
fi
flock -u 7
exec 7>&-

cwd="$(realpath "$PWD")"
setup="cd $(printf '%q' "$cwd") && export DEV_PROJECT=$(printf '%q' "$(basename "$project")")"
if [ $# -eq 0 ]; then
  remote="$setup && exec bash -l"
else
  printf -v quoted '%q ' "$@"
  remote="$setup && exec bash -lc $(printf '%q' "exec ${quoted% }")"
fi

tty_flag=-T
[ -t 0 ] && [ -t 1 ] && tty_flag=-tt
set +e
ssh "$tty_flag" "${ssh_args[@]}" dev "$remote"
exit $?
