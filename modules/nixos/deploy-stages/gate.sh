#!/usr/bin/env bash
# Deploy gate (deploy-stages/default.nix): lets comin deploy the waiting
# generation once
# - every upstream host has deployed the same commit and run it for
#   GATE_WAIT seconds, or
# - the commit has waited GATE_MAX_WAIT seconds here and every upstream host
#   stayed healthy. comin doesn't record a commit that leaves a host's system
#   unchanged, so a fuji-only change never shows up on the thinkcentre; this
#   lets it through.
# Either way an upstream host must be healthy: its comin answers (the switch
# guard holds it after a rollback, so a host a change cut off blocks the
# gate), its last deployment didn't fail, and it isn't suspended.
#
# Settings come from the environment:
#   GATE_UPSTREAM  "name=metrics-url ..." (comin's exporter on each upstream host)
#   GATE_WAIT      seconds an upstream host has to have run the commit
#   GATE_MAX_WAIT  seconds after which a commit goes if the upstream hosts are healthy
#   GATE_STATE     folder for when each host was first seen on a commit
set -u

now=$(date +%s)
mkdir -p "$GATE_STATE"

status=$(comin status --json 2>/dev/null) || { echo "comin doesn't answer here; nothing to do"; exit 0; }
pending=$(jq -r '.deploy_confirmer.submitted // empty' <<<"$status")
if [ -z "$pending" ]; then
  exit 0
fi
commit=$(jq -r --arg u "$pending" '
  [.. | objects | select(.uuid? == $u)
   | (.source.git.selected_commit_id // .selected_commit_id // "")
   | select(. != "")] | first // empty' <<<"$status")
if [ -z "$commit" ]; then
  echo "can't tell which commit generation $pending is; waiting"
  exit 0
fi

# How long this commit has been waiting here.
waiting_commit="" waiting_since=""
[ -f "$GATE_STATE/pending" ] && read -r waiting_commit waiting_since < "$GATE_STATE/pending"
if [ "$waiting_commit" != "$commit" ] || [ -z "$waiting_since" ]; then
  waiting_since=$now
  echo "$commit $waiting_since" > "$GATE_STATE/pending"
fi
waited=$(( now - waiting_since ))

# Every host is looked at on every run, so their waits run side by side.
ready=yes healthy=yes
for entry in $GATE_UPSTREAM; do
  name=${entry%%=*} url=${entry#*=}
  metrics=$(curl -fsS -m 10 "$url" 2>/dev/null) || {
    rm -f "$GATE_STATE/$name"
    echo "waiting for ${commit:0:7}: $name's comin doesn't answer (held after a rollback, or down)"
    ready=no healthy=no
    continue
  }
  if ! grep -qx "comin_last_deployment_failed 0" <<<"$metrics" || ! grep -qx "comin_is_suspended 0" <<<"$metrics"; then
    rm -f "$GATE_STATE/$name"
    echo "waiting for ${commit:0:7}: $name's last deployment failed, or it's suspended"
    ready=no healthy=no
    continue
  fi
  if ! grep -qF "comin_deployment_info{commit_id=\"$commit\",status=\"done\"} 1" <<<"$metrics"; then
    rm -f "$GATE_STATE/$name"
    echo "waiting for ${commit:0:7}: $name hasn't deployed it yet"
    ready=no
    continue
  fi
  # When this host was first seen running the commit.
  seen_commit="" seen=""
  [ -f "$GATE_STATE/$name" ] && read -r seen_commit seen < "$GATE_STATE/$name"
  if [ -z "$seen" ] || [ "$seen_commit" != "$commit" ]; then
    seen=$now
    echo "$commit $seen" > "$GATE_STATE/$name"
  fi
  age=$(( now - seen ))
  if [ "$age" -lt "$GATE_WAIT" ]; then
    echo "waiting for ${commit:0:7}: $name has run it for ${age} s of ${GATE_WAIT}"
    ready=no
  fi
done
if [ "$ready" = yes ]; then
  echo "deploying ${commit:0:7}: every upstream host has run it for ${GATE_WAIT} s"
elif [ "$healthy" = yes ] && [ "$waited" -ge "$GATE_MAX_WAIT" ]; then
  echo "deploying ${commit:0:7}: waited ${waited} s and every upstream host stayed healthy (it doesn't change them, or they haven't got to it)"
else
  exit 0
fi
rm -f "$GATE_STATE/pending"
comin confirmation accept
