#!/usr/bin/env bash
# Add sites to the current host's declarative LibreWolf cookie allow-list.
set -euo pipefail

repo="${NIXOS_CONFIG:-$HOME/git/dotfiles}"
case "$(hostname)" in
  workstation) file="$repo/home/nixa/librewolf-cookie-allow.txt" ;;
  nixpad)      file="$repo/home/bro/librewolf-cookie-allow.txt" ;;
  *) echo "unsupported hostname: $(hostname) (expected workstation or nixpad)" >&2; exit 1 ;;
esac

[ -f "$file" ] || { echo "not found: $file" >&2; exit 1; }
[ "$#" -gt 0 ] || { echo "usage: cookie-allow <url-or-domain> [more...]" >&2; exit 1; }

normalize() {
  local host="${1,,}"
  host="${host#http://}"; host="${host#https://}"
  host="${host%%/*}"; host="${host%%\?*}"; host="${host%%:*}"
  [[ "$host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || return 1
  printf 'https://%s' "$host"
}

mapfile -t origins < <(grep '^https://' "$file" || true)
added=()
failed=0
for arg in "$@"; do
  if origin="$(normalize "$arg")"; then
    if printf '%s\n' "${origins[@]}" | grep -qxF "$origin"; then
      echo "skip $origin — already listed"
    else
      origins+=("$origin")
      added+=("$origin")
    fi
  else
    echo "skip $arg — not a valid domain" >&2
    failed=1
  fi
done

if [ "${#added[@]}" -eq 0 ]; then
  echo "nothing added — no rebuild needed"
  exit "$failed"
fi

tmp="$(mktemp "$file.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
grep '^#' "$file" > "$tmp" || true
echo >> "$tmp"
printf '%s\n' "${origins[@]}" | sort -u >> "$tmp"
mv "$tmp" "$file"
trap - EXIT

printf 'added: %s\n' "${added[@]}"
git -C "$repo" add "$file" 2>/dev/null || true
echo
echo "then: sudo nixos-rebuild switch --flake $repo#$(hostname)"
exit "$failed"
