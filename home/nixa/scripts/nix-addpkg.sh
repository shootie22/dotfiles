#!/usr/bin/env bash
# Add package(s) to packages.txt (or system-packages.txt with --system), then
# remind to rebuild. Validates each name against the flake's *locked* nixpkgs,
# so a typo is caught here instead of halfway through a rebuild, and skips
# anything already listed in either file.
set -euo pipefail

repo="${NIXOS_CONFIG:-$HOME/git/dotfiles}"
user_file="$repo/home/nixa/packages.txt"
system_file="$repo/hosts/workstation/system-packages.txt"

target="$user_file"
scope="home.packages"
comment=""

usage() {
    cat >&2 <<'EOF'
usage: nix-addpkg [-u | -s] [-m COMMENT] <package> [more...]

  -u, --user    add to packages.txt -> home.packages (the default: your
                user profile)
  -s, --system  add to system-packages.txt -> environment.systemPackages,
                for things root, a TTY, or a systemd service needs
  -m COMMENT    append "# COMMENT" to each added line
  -l, --list    list what's currently in both files and exit

Names may be dotted, e.g. kdePackages.konsole.
EOF
    exit 1
}

# Package names on a line, ignoring blanks and comments.
names_in() {
    sed 's/#.*//' "$1" | awk 'NF { print $1 }'
}

args=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|--system)  target="$system_file"; scope="environment.systemPackages"; shift ;;
        -u|--user)    target="$user_file";   scope="home.packages";             shift ;;
        -m)           [ "$#" -ge 2 ] || usage; comment="$2"; shift 2 ;;
        -l|--list)
            for f in "$user_file" "$system_file"; do
                echo "== $(basename "$f")"
                names_in "$f" | sed 's/^/  /'
            done
            exit 0 ;;
        -h|--help)    usage ;;
        -*)           echo "unknown option: $1" >&2; usage ;;
        *)            args+=("$1"); shift ;;
    esac
done

[ "${#args[@]}" -gt 0 ] || usage
for f in "$user_file" "$system_file"; do
    [ -f "$f" ] || { echo "not found: $f" >&2; exit 1; }
done

# Resolve a name against the flake's locked nixpkgs. Echoes the derivation
# name, or MISSING / NOTPKG / ERROR.
validate() {
    nix eval --raw --impure --expr "
      let f = builtins.getFlake \"$repo\";
          lib = f.inputs.nixpkgs.lib;
          pkgs = f.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
          r = builtins.tryEval (lib.attrByPath (lib.splitString \".\" \"$1\") null pkgs);
      in if !r.success then \"ERROR\"
         else if r.value == null then \"MISSING\"
         else if !(lib.isDerivation r.value) then \"NOTPKG\"
         else r.value.name" 2>/dev/null || echo ERROR
}

added=() failed=0
for pkg in "${args[@]}"; do
    if [[ ! "$pkg" =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]]; then
        echo "skip $pkg — not a valid attribute name" >&2
        failed=1
        continue
    fi

    # Already listed? Say which file, so --system vs user is obvious.
    where=""
    if names_in "$user_file" | grep -qxF "$pkg"; then
        where="packages.txt"
    elif names_in "$system_file" | grep -qxF "$pkg"; then
        where="system-packages.txt"
    fi
    if [ -n "$where" ]; then
        echo "skip $pkg — already in $where"
        continue
    fi

    drv="$(validate "$pkg")"
    case "$drv" in
        MISSING) echo "skip $pkg — no such package in nixpkgs" >&2; failed=1; continue ;;
        NOTPKG)  echo "skip $pkg — exists but isn't a package (it's an attribute set)" >&2; failed=1; continue ;;
        ERROR)   echo "skip $pkg — failed to evaluate" >&2; failed=1; continue ;;
    esac

    # Keep the file's own grouping intact: append rather than re-sort.
    if [ -n "$comment" ]; then
        printf '%s  # %s\n' "$pkg" "$comment" >> "$target"
    else
        printf '%s\n' "$pkg" >> "$target"
    fi
    added+=("$pkg ($drv)")
done

if [ "${#added[@]}" -eq 0 ]; then
    echo "nothing added"
    exit $(( failed ? 1 : 0 ))
fi

printf 'added to %s -> %s:\n' "$(basename "$target")" "$scope"
printf '  %s\n' "${added[@]}"
git -C "$repo" add "$target" 2>/dev/null || true
echo
echo "then: sudo nixos-rebuild switch --flake $repo#workstation"
exit $(( failed ? 1 : 0 ))
