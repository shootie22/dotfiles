#!/usr/bin/env bash
# tofu applier (infra-hub #48). Every few minutes: if main's tofu/
# changed since the last apply, plan, and apply only when the plan is exactly
# the DNS records the change added, changed or removed. Anything else is left
# alone and reported through the relay, once per commit. The new state is
# committed back to main with a deploy key the ruleset lets through.
set -euo pipefail

repo=git@github.com:shootie22/infrastructure.git
work=$STATE_DIRECTORY/infrastructure
applied_file=$STATE_DIRECTORY/applied   # last commit whose tofu/ is live
alerted_file=$STATE_DIRECTORY/alerted   # last commit an alert was sent for
relay=http://10.99.0.1:9190/alert       # the edge's alert relay, over Nebula
records_awk=$RECORDS_AWK

export HOME=$STATE_DIRECTORY
export GIT_SSH_COMMAND="ssh -i $CREDENTIALS_DIRECTORY/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"
export SOPS_AGE_KEY_FILE=$CREDENTIALS_DIRECTORY/age_key
export TF_DATA_DIR=$STATE_DIRECTORY/tofu-data
export TF_PLUGIN_CACHE_DIR=$STATE_DIRECTORY/plugins
mkdir -p "$TF_PLUGIN_CACHE_DIR"

notify() {
  local head=$1 title=$2 msg=$3
  if [[ $(cat "$alerted_file" 2>/dev/null) == "$head" ]]; then return; fi
  curl -fsS -m 10 -X POST "$relay" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg t "$title" --arg m "$msg" '{title: $t, message: $m}')" >/dev/null \
    || echo "relay unreachable: $title"
  echo "$head" > "$alerted_file"
}

[[ -d $work/.git ]] || git clone -q "$repo" "$work"
cd "$work"
git config user.name "tofu applier on fuji"
git config user.email "tofu-apply@fuji"
git fetch -q origin
git checkout -q -B main origin/main
git reset -q --hard origin/main
git clean -qfdx -e .terraform
head=$(git rev-parse HEAD)

# The first run only notes where main is: what's there now was applied by hand.
if [[ ! -s $applied_file ]]; then
  echo "$head" > "$applied_file"
  echo "starting from $head"
  exit 0
fi
applied=$(cat "$applied_file")
if [[ $applied == "$head" ]]; then exit 0; fi

changed=$(git diff --name-only "$applied" "$head" -- tofu/ | grep -v '^tofu/terraform\.tfstate' || true)
if [[ -z $changed ]]; then
  echo "$head" > "$applied_file"
  exit 0
fi
others=$(grep -vx 'tofu/dns-records.tf' <<<"$changed" || true)
if [[ -n $others ]]; then
  notify "$head" "tofu: not applied" "main changed $(tr '\n' ' ' <<<"$others")in tofu/ since ${applied:0:7}; only DNS records are applied on their own. Run scripts/tofu apply by hand."
  exit 0
fi

# The records the change touched: keys whose entry differs between the two.
diff <(git show "$applied:tofu/dns-records.tf" | awk -f "$records_awk" | sort) \
     <(awk -f "$records_awk" tofu/dns-records.tf | sort) \
  | sed -n 's/^[<>] \([^\t]*\)\t.*/\1/p' | sort -u > "$STATE_DIRECTORY/keys"
echo "records changed: $(tr '\n' ' ' < "$STATE_DIRECTORY/keys")"

scripts/tofu init -input=false -no-color >/dev/null
scripts/tofu plan -input=false -no-color -out="$STATE_DIRECTORY/plan" >/dev/null
scripts/tofu show -json "$STATE_DIRECTORY/plan" \
  | jq -r '.resource_changes[] | select(.change.actions != ["no-op"]) | [.type, .name, (.index // ""), (.change.actions | join(","))] | @tsv' \
  > "$STATE_DIRECTORY/changes"

# Each change has to be the Cloudflare record or the deSEC standby copy of a
# changed key (the standby copy is keyed zone/name/type, the record may add
# a suffix).
unexpected=()
while IFS=$'\t' read -r type name index actions; do
  ok=false
  if [[ $type.$name == cloudflare_dns_record.this ]] && grep -qxF "$index" "$STATE_DIRECTORY/keys"; then ok=true; fi
  if [[ $type.$name == desec_rrset.standby && $index =~ ^[^/]+/[^/]+/[^/]+$ ]] && grep -qE "^$(sed 's/[][\.*^$/]/\\&/g' <<<"$index")(/|$)" "$STATE_DIRECTORY/keys"; then ok=true; fi
  $ok || unexpected+=("$type.$name[\"$index\"] ($actions)")
done < "$STATE_DIRECTORY/changes"

if ((${#unexpected[@]})); then
  notify "$head" "tofu: not applied" "The plan for ${head:0:7} changes more than its DNS records: ${unexpected[*]}. Run scripts/tofu plan by hand and see."
  exit 0
fi
if [[ ! -s $STATE_DIRECTORY/changes ]]; then
  echo "$head" > "$applied_file"
  exit 0
fi

echo "applying: $(cut -f1-3 "$STATE_DIRECTORY/changes" | tr '\t\n' '  ')"
if ! scripts/tofu apply -input=false -no-color "$STATE_DIRECTORY/plan"; then
  notify "$head" "tofu: apply failed" "Applying ${head:0:7} failed on fuji; see journalctl -u tofu-apply. The state may be partly changed."
  # Save what state there is, so the next run plans from it.
fi
git add tofu/terraform.tfstate tofu/terraform.tfstate.backup 2>/dev/null || true
if ! git diff --cached --quiet; then
  subjects=$(git log --format=%s "$applied..$head" -- tofu/dns-records.tf | head -3 | paste -sd ';' -)
  git commit -q -m "tofu: state after ${subjects:-${head:0:7}}"
  for _ in 1 2 3; do
    git push -q origin main && break
    git fetch -q origin && git rebase -q origin/main || { notify "$head" "tofu: state not pushed" "The state after ${head:0:7} couldn't be pushed; it's in $work on fuji."; exit 1; }
  done
fi
git rev-parse HEAD > "$applied_file"
