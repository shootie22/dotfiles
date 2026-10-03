#!/usr/bin/env bash
# Weekly update (infrastructure repo, #84). Updates flake.lock, builds every
# x86_64 host before and after, and pushes the result to an update-DATE branch
# with a report of what changes. A GitHub workflow turns it into a pull
# request; nothing reaches main (and so the servers) until it's merged.
set -euo pipefail

repo=git@github.com:shootie22/dotfiles.git
work=$STATE_DIRECTORY/dotfiles
relay=http://100.64.0.9:9190/alert
build_hosts=(edge fuji thinkcentre nixpad workstation)
eval_hosts=(mixi minima-vm)   # aarch64, can't build here
today=$(date +%F)
branch=update-$today

export HOME=$STATE_DIRECTORY
export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

notify() {
  curl -fsS -m 10 -X POST "$relay" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$1" --arg m "$2" '{title: $t, message: $m}')" >/dev/null \
    || echo "relay unreachable: $1"
}
# healthchecks.io expects a ping every week (infrastructure tofu/healthchecks.tf):
# silence means the job didn't run or didn't finish. Failures alert through
# the relay instead.
done_ok() { curl -fsS -m 10 --retry 3 -o /dev/null "$(cat "$CREDENTIALS_DIRECTORY/ping_url")" || echo "healthchecks.io unreachable"; }
build() { nix build --no-link --print-out-paths ".#nixosConfigurations.$1.config.system.build.toplevel"; }
ver() { nix eval --raw ".#nixosConfigurations.$1.$2" 2>/dev/null || echo "?"; }

[[ -d $work/.git ]] || git clone -q "$repo" "$work"
cd "$work"
git fetch -q origin
git checkout -q -B main origin/main
git reset -q --hard origin/main
git clean -qfdx

declare -A old new
for h in "${build_hosts[@]}"; do
  old[$h]=$(build "$h") || { notify "Weekly update failed" "$h doesn't build on the current main."; exit 1; }
done
old_k3s=$(ver fuji config.services.k3s.package.version)
old_kernel=$(ver fuji config.boot.kernelPackages.kernel.version)

nix flake update 2>&1 | grep -E '^• Updated' || true
if git diff --quiet flake.lock; then
  echo "nothing new this week"
  done_ok
  exit 0
fi

failed=()
for h in "${build_hosts[@]}"; do
  new[$h]=$(build "$h") || failed+=("$h")
done
for h in "${eval_hosts[@]}"; do
  nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" >/dev/null || failed+=("$h (evaluation)")
done
if ((${#failed[@]})); then
  notify "Weekly update failed" "Doesn't build with the new versions: ${failed[*]}. Nothing was proposed."
  exit 1
fi
new_k3s=$(ver fuji config.services.k3s.package.version)
new_kernel=$(ver fuji config.boot.kernelPackages.kernel.version)

{
  echo "Built every x86_64 host with the new versions, and evaluated minima-vm. mixi isn't checked here (its config needs --impure)."
  echo
  echo "Merging rolls it out: the edge, fuji, mixi and minima update themselves through comin; the desktops on their next rebuild. The thinkcentre is built here but still runs Debian."
  echo
  minor() { cut -d. -f1,2 <<<"$1"; }
  if [[ $(minor "$old_k3s") != $(minor "$new_k3s") ]]; then
    echo "**⚠ k3s minor version change: $old_k3s → $new_k3s.** Read the k3s release notes before merging."
    echo
  fi
  if [[ $(minor "$old_kernel") != $(minor "$new_kernel") ]]; then
    echo "**⚠ New kernel series: $old_kernel → $new_kernel.**"
    echo
  fi
  for h in "${build_hosts[@]}"; do
    echo "### $h"
    echo
    echo '```'
    nix store diff-closures "${old[$h]}" "${new[$h]}" | sed -E 's/\x1b\[[0-9;]*m//g' | grep -v '^$' || true
    echo '```'
    echo
  done
  echo "Inputs:"
  echo
  echo '```'
  nix flake metadata --json | jq -r '.locks.nodes | to_entries[] | select(.value.locked.lastModified) | "\(.key) \(.value.locked.lastModified | todate | .[0:10])"' | sort
  echo '```'
} > "$STATE_DIRECTORY/report.md"

git -c user.name="fuji weekly update" -c user.email="fuji@radunenu.com" \
  commit -q -F - flake.lock <<MSG
Weekly update $today

$(cat "$STATE_DIRECTORY/report.md")
MSG
git push -q -f origin "HEAD:refs/heads/$branch"
notify "Update pending" "New versions for $today are ready to review: https://github.com/shootie22/dotfiles/pulls"
echo "pushed $branch"
done_ok
