#!/usr/bin/env bash
# Weekly update (infrastructure repo, #84). Updates flake.lock, builds every
# x86_64 host before and after, and pushes the result to an update-DATE branch
# with a report of what changes. A GitHub workflow turns it into a pull
# request; nothing reaches main (and so the servers) until it's merged.
set -euo pipefail

repo=git@github.com:shootie22/dotfiles.git
work=$STATE_DIRECTORY/dotfiles
relay=http://10.99.0.1:9190/alert  # the edge's alert relay, over Nebula
build_hosts=(edge fuji thinkcentre)
# Evaluated only: mixi and minima-vm are aarch64, and the desktops build
# themselves (the workstation pre-builds both, modules/nixos/desktop-prebuild.nix);
# their rustc, Electron apps and CachyOS kernel took fuji hours.
eval_hosts=(mixi minima-vm)
# The desktops don't hold the servers back: if one doesn't evaluate with the
# new versions, the pull request says why, and it gets fixed before its next
# rebuild.
desktop_hosts=(nixpad workstation)
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
# Anything else that stops the script (set -e) alerts too; healthchecks.io only
# notices a week later, and its alerts go to Pushover, which is off.
trap 'notify "Weekly update failed" "Line $LINENO of update.sh failed. journalctl -u weekly-update on fuji."' ERR
build() { nix build --no-link --print-out-paths ".#nixosConfigurations.$1.config.system.build.toplevel"; }
ver() { nix eval --raw ".#nixosConfigurations.$1.$2" 2>/dev/null || echo "?"; }

[[ -d $work/.git ]] || git clone -q "$repo" "$work"
cd "$work"
git fetch -q origin
# -f: a run that stopped halfway leaves a changed flake.lock behind, and a
# plain checkout refuses to overwrite it (the 2026-10-31 run failed on
# that).
git checkout -q -f -B main origin/main
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
declare -A desktop_errors
for h in "${desktop_hosts[@]}"; do
  if ! err=$(nix eval --raw ".#nixosConfigurations.$h.config.system.build.toplevel.drvPath" 2>&1 >/dev/null); then
    # The assertions, or else the last lines, are what says what to change.
    desktop_errors[$h]=$(grep -E '^\s*- ' <<<"$err" || tail -n 5 <<<"$err")
  fi
done
if ((${#failed[@]})); then
  notify "Weekly update failed" "Doesn't build with the new versions: ${failed[*]}. Nothing was proposed."
  exit 1
fi
new_k3s=$(ver fuji config.services.k3s.package.version)
new_kernel=$(ver fuji config.boot.kernelPackages.kernel.version)

{
  echo "Built the x86_64 servers with the new versions, and evaluated minima-vm and the desktops. mixi isn't checked here (its config needs --impure)."
  echo
  echo "Merging rolls it out: the edge, fuji, mixi, the thinkcentre and minima update themselves through comin; the desktops on their next rebuild (the workstation builds both in the background within an hour of the merge, while it's on). A new kernel needs a reboot by hand on fuji, mixi and the thinkcentre (their disks are unlocked by hand); the edge and minima reboot into it at 04:00."
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
  for h in "${!desktop_errors[@]}"; do
    echo "**⚠ $h doesn't evaluate with these versions.** Fix its configuration before rebuilding it:"
    echo
    echo '```'
    echo "${desktop_errors[$h]}"
    echo '```'
    echo
  done
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
