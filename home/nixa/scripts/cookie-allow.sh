#!/usr/bin/env bash
# Add site(s) to the LibreWolf cookie allow-list (librewolf-cookie-allow.txt),
# then remind to rebuild. Normalises input to an "https://host" origin,
# de-duplicates, keeps the file sorted, and leaves the comment header intact.
set -euo pipefail

repo="${NIXOS_CONFIG:-$HOME/git/dotfiles}"
file="$repo/home/nixa/librewolf-cookie-allow.txt"

[ -f "$file" ] || { echo "not found: $file" >&2; exit 1; }
if [ "$#" -eq 0 ]; then
    echo "usage: cookie-allow <url-or-domain> [more...]" >&2
    exit 1
fi

normalize() {
    local h="${1,,}"
    h="${h#http://}"; h="${h#https://}"
    h="${h%%/*}"        # drop path
    h="${h%%\?*}"       # drop query
    h="${h%%:*}"        # drop port
    [[ "$h" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || return 1
    printf 'https://%s' "$h"
}

# existing origins (lines starting with https://)
mapfile -t origins < <(grep '^https://' "$file" || true)

added=()
failed=0
for arg in "$@"; do
    if origin="$(normalize "$arg")"; then
        if printf '%s\n' ${origins[@]+"${origins[@]}"} | grep -qxF "$origin"; then
            echo "skip $origin — already listed"
            continue
        fi
        origins+=("$origin")
        added+=("$origin")
    else
        echo "skip $arg — not a valid domain" >&2
        failed=1
    fi
done

# Nothing new? Leave the file (and its mtime) alone.
if [ "${#added[@]}" -eq 0 ]; then
    echo "nothing added — no rebuild needed"
    exit "$failed"
fi

# rewrite: comment header, blank line, then sorted-unique origins
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
echo "then: sudo nixos-rebuild switch --flake $repo#workstation"
exit "$failed"
