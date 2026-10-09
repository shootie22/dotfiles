#!/usr/bin/env bash
# Makes the deploy key fuji's tofu applier pushes the state with
# (modules/nixos/tofu-apply, infra-hub #48): a new SSH key, its
# private half encrypted into secrets/tofu-apply.yaml (fuji + personal key),
# its public half added to the infrastructure repo as a deploy key with
# write access, and the repo's main ruleset told to let deploy keys through.
# Run on nixpad from the dotfiles checkout, logged in with gh.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
for bin in sops gh ssh-keygen jq; do
  command -v "$bin" >/dev/null || { printf '%s is required; try: nix shell nixpkgs#sops nixpkgs#gh nixpkgs#jq -c bash %s\n' "$bin" "$0" >&2; exit 1; }
done

target=secrets/tofu-apply.yaml
repo=shootie22/infrastructure
ruleset=24411919   # "main: changes only through pull requests"
if [[ -e $target ]]; then
  printf 'Refusing to overwrite %s\n' "$target" >&2
  exit 1
fi

umask 077
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C 'fuji tofu-apply' -f "$dir/key"

{
  printf 'deploy_key: |\n'
  sed 's/^/  /' "$dir/key"
} | sops --encrypt --filename-override "$target" --input-type yaml --output-type yaml /dev/stdin > "$dir/enc"
mv -- "$dir/enc" "$target"

gh api "repos/$repo/keys" -f title='fuji tofu-apply (pushes tofu state to main)' \
  -f key="$(cat "$dir/key.pub")" -F read_only=false --jq '"deploy key \(.id) added to '"$repo"'"'

# Let deploy keys past the ruleset (this one is the repo's only deploy key).
gh api "repos/$repo/rulesets/$ruleset" \
  | jq '{bypass_actors: ((.bypass_actors | map(select(.actor_type != "DeployKey"))) + [{actor_type: "DeployKey", bypass_mode: "always"}])}' \
  | gh api -X PUT "repos/$repo/rulesets/$ruleset" --input - --jq '"ruleset bypass: \(.bypass_actors | map(.actor_type) | join(", "))"'

printf 'Encrypted key written: %s\n' "$target"
