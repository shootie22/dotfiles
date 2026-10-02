#!/usr/bin/env bash
# Hourly DNSSEC check for the multi-signer zones (infrastructure repo,
# docs/ha). For each zone:
#  1. public resolvers return it validated (the ad flag)
#  2. every DS record at the registry matches a key that Cloudflare or deSEC
#     publishes, and both providers' answers validate against those keys
#     (this is what breaks if Cloudflare rotates its keys and deSEC still
#     publishes the old one)
# Problems go to the alert relay on the edge, once per distinct problem set.
# IPv4 only (-4): the edge has no IPv6, and delv would otherwise try it first.
set -uo pipefail

zones=(byradu.com cubi.tube cubtube.lol kronorite.com radunenu.com yeetus.net)
cloudflare_ns=nola.ns.cloudflare.com
desec_ns=ns1.desec.io
relay=http://127.0.0.1:9190/alert
state=${STATE_DIRECTORY:-/tmp}/last-problems
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

problems=()

for z in "${zones[@]}"; do
  for r in 1.1.1.1 8.8.8.8; do
    if ! dig +dnssec +time=5 +tries=2 "$z" SOA "@$r" | grep -q 'flags:.* ad'; then
      problems+=("$z doesn't validate at $r")
    fi
  done

  # Keys both providers publish, and the DS records the registry publishes.
  { dig +short +time=5 "$z" DNSKEY "@$cloudflare_ns"; dig +short +time=5 "$z" DNSKEY "@$desec_ns"; } \
    | awk -v z="$z" '$1 == 257 { k = ""; for (i = 4; i <= NF; i++) k = k $i; print z ". 3600 IN DNSKEY", $1, $2, $3, k }' \
    | sort -u > "$work/$z.keys"
  tld_ns=$(dig +short "${z##*.}." NS | head -1)
  dig +short "$z" DS "@$tld_ns" | awk '$3 == 2 { d = ""; for (i = 4; i <= NF; i++) d = d $i; print $1, toupper(d) }' \
    | sort -u > "$work/$z.ds"
  dnssec-dsfromkey -2 -f "$work/$z.keys" "$z" 2>/dev/null \
    | awk '{ print $4, toupper($7 $8) }' | sort -u > "$work/$z.ds-from-keys"
  while read -r ds; do
    grep -qx "$ds" "$work/$z.ds-from-keys" || problems+=("$z: DS ${ds%% *} at the registry has no matching key")
  done < "$work/$z.ds"

  # Validate each provider's answers against the published keys.
  { echo 'trust-anchors {'
    awk '{ printf "  \"%s\" static-key %s %s %s \"%s\";\n", $1, $5, $6, $7, $8 }' "$work/$z.keys"
    echo '};'; } > "$work/$z.anchors"
  for ns in "$cloudflare_ns" "$desec_ns"; do
    if ! delv -4 -a "$work/$z.anchors" +root="$z" "@$ns" "$z" SOA 2>&1 | grep -q "^; fully validated"; then
      problems+=("$z doesn't validate at $ns")
    fi
  done
done

summary=$(printf '%s\n' "${problems[@]}" | sort)
last=$(cat "$state" 2>/dev/null || true)
if [[ ${#problems[@]} -eq 0 ]]; then
  echo "all ${#zones[@]} zones validate"
  [[ -n $last ]] && curl -fsS -m 10 -X POST "$relay" \
    -d '{"title":"DNSSEC fine again","message":"All zones validate on both providers."}' >/dev/null
  : > "$state"
  exit 0
fi

printf '%s\n' "$summary"
if [[ $summary != "$last" ]]; then
  body=$(jq -n --arg m "$summary" '{title: "DNSSEC problem", message: $m}')
  curl -fsS -m 10 -X POST "$relay" -d "$body" >/dev/null || echo "relay unreachable"
fi
printf '%s' "$summary" > "$state"
exit 1
