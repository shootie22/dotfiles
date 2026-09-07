#!/usr/bin/env bash
# Add packages to the current host's tracked user or system package list.
set -euo pipefail

repo="${NIXOS_CONFIG:-$HOME/git/dotfiles}"
host="$(hostname)"

case "$host" in
  workstation)
    user_file="$repo/home/nixa/packages.txt"
    system_file="$repo/hosts/workstation/system-packages.txt"
    nixpkgs_input="nixpkgs"
    ;;
  nixpad)
    user_file="$repo/home/bro/packages.txt"
    system_file="$repo/hosts/nixpad/system-packages.txt"
    nixpkgs_input="nixpkgs-nixpad"
    ;;
  *)
    echo "unsupported hostname: $host (expected workstation or nixpad)" >&2
    exit 1
    ;;
esac

target="$user_file"
scope="home.packages"
comment=""

usage() {
  cat >&2 <<'EOF'
usage: nix-addpkg [-u | -s] [-m COMMENT] <package> [more...]

  -u, --user    add to the user's home.packages list (default)
  -s, --system  add to the host's environment.systemPackages list
  -m COMMENT    append "# COMMENT" to each added line
  -l, --list    list both package files and exit

Names may be dotted, e.g. kdePackages.konsole. On nixpad, use unstable.NAME
for a package intentionally sourced from its unstable input.
EOF
  exit 1
}

names_in() { sed 's/#.*//' "$1" | awk 'NF { print $1 }'; }

args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|--system) target="$system_file"; scope="environment.systemPackages"; shift ;;
    -u|--user) target="$user_file"; scope="home.packages"; shift ;;
    -m) [ "$#" -ge 2 ] || usage; comment="$2"; shift 2 ;;
    -l|--list)
      for file in "$user_file" "$system_file"; do
        echo "== $(basename "$file")"
        names_in "$file" | sed 's/^/  /'
      done
      exit 0
      ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) args+=("$1"); shift ;;
  esac
done

[ "${#args[@]}" -gt 0 ] || usage
for file in "$user_file" "$system_file"; do
  [ -f "$file" ] || { echo "not found: $file" >&2; exit 1; }
done

validate() {
  nix eval --raw --impure --expr "
    let
      f = builtins.getFlake \"$repo\";
      pkgs = f.inputs.\"$nixpkgs_input\".legacyPackages.\${builtins.currentSystem};
      unstable = if f.inputs ? nixpkgs-nixpad-unstable
        then f.inputs.nixpkgs-nixpad-unstable.legacyPackages.\${builtins.currentSystem}
        else pkgs;
      name = \"$1\";
      isUnstable = builtins.match \"^unstable\\..*\" name != null;
      source = if isUnstable then unstable else pkgs;
      path = lib.splitString \".\" (if isUnstable then builtins.substring 9 (builtins.stringLength name - 9) name else name);
      lib = pkgs.lib;
      result = builtins.tryEval (lib.attrByPath path null source);
    in if !result.success then \"ERROR\"
       else if result.value == null then \"MISSING\"
       else if !(lib.isDerivation result.value) then \"NOTPKG\"
       else result.value.name" 2>/dev/null || echo ERROR
}

added=()
failed=0
for pkg in "${args[@]}"; do
  if [[ ! "$pkg" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]]; then
    echo "skip $pkg — not a valid attribute name" >&2
    failed=1
    continue
  fi
  where=""
  if names_in "$user_file" | grep -qxF "$pkg"; then
    where="$(basename "$user_file")"
  elif names_in "$system_file" | grep -qxF "$pkg"; then
    where="$(basename "$system_file")"
  fi
  if [ -n "$where" ]; then
    echo "skip $pkg — already in $where"
    continue
  fi
  drv="$(validate "$pkg")"
  case "$drv" in
    MISSING) echo "skip $pkg — no such package in nixpkgs" >&2; failed=1; continue ;;
    NOTPKG) echo "skip $pkg — exists but is not a package" >&2; failed=1; continue ;;
    ERROR) echo "skip $pkg — failed to evaluate" >&2; failed=1; continue ;;
  esac
  if [ -n "$comment" ]; then
    printf '%s  # %s\n' "$pkg" "$comment" >> "$target"
  else
    printf '%s\n' "$pkg" >> "$target"
  fi
  added+=("$pkg ($drv)")
done

if [ "${#added[@]}" -eq 0 ]; then
  echo "nothing added"
  exit "$failed"
fi

printf 'added to %s -> %s:\n' "$(basename "$target")" "$scope"
printf '  %s\n' "${added[@]}"
git -C "$repo" add "$target" 2>/dev/null || true
echo
echo "then: sudo nixos-rebuild switch --flake $repo#$host"
exit "$failed"
