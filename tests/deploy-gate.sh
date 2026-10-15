#!/usr/bin/env bash
# Tests for modules/nixos/deploy-stages/gate.sh, with a stand-in comin and
# stand-in upstream exporters.
#
#   nix build .#checks.x86_64-linux.deploy-gate -L
set -u
gate=$GATE_SCRIPT
work=$(mktemp -d)
mkdir -p "$work/bin" "$work/www/a" "$work/www/b" "$work/state"
failures=0

# comin: `status --json` prints $work/status.json, `confirmation accept`
# leaves a mark.
cat > "$work/bin/comin" <<EOF
#!$(command -v bash)
case "\$1 \${2:-}" in
  "status --json") cat "$work/status.json" ;;
  "confirmation accept") echo accepted >> "$work/accepted" ;;
esac
EOF
chmod +x "$work/bin/comin"
export PATH="$work/bin:$PATH"

python3 -m http.server 38200 --bind 127.0.0.1 --directory "$work/www" >/dev/null 2>&1 &
server=$!
trap 'kill $server' EXIT
sleep 1

export GATE_UPSTREAM="a=http://127.0.0.1:38200/a/metrics b=http://127.0.0.1:38200/b/metrics"
export GATE_WAIT=2
export GATE_MAX_WAIT=6
export GATE_STATE="$work/state"

pending() { # uuid commit [deprecated layout]
  if [ "${3:-}" = old ]; then
    printf '{"deploy_confirmer":{"submitted":"%s"},"builder":{"generation":{"uuid":"%s","selected_commit_id":"%s"}}}' "$1" "$1" "$2"
  else
    printf '{"deploy_confirmer":{"submitted":"%s"},"builder":{"generation":{"uuid":"%s","source":{"git":{"selected_commit_id":"%s"}}}}}' "$1" "$1" "$2"
  fi > "$work/status.json"
}
upstream() { # host commit status
  failed=0; [ "$3" = failed ] && failed=1
  printf 'comin_deployment_info{commit_id="%s",status="%s"} 1\ncomin_is_suspended %s\ncomin_last_deployment_failed %s\n' "$2" "$3" "${4:-0}" "$failed" > "$work/www/$1/metrics"
}
run() { rm -f "$work/accepted"; out=$(bash "$gate"); echo "    $out"; }
expect() { # name accepted|waiting
  local got=waiting
  [ -f "$work/accepted" ] && got=accepted
  if [ "$got" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: got $got, want $2"; failures=$((failures + 1)); fi
}

echo '{"deploy_confirmer":{"submitted":""}}' > "$work/status.json"
run; expect "nothing waiting" waiting

pending g1 aaaa1111
upstream a aaaa1111 done; upstream b 0000old0 done
run; expect "one upstream host still on the old commit" waiting

upstream b aaaa1111 done
run; expect "both on it, but only just" waiting
sleep 3
run; expect "both have run it for the wait" accepted

pending g2 bbbb2222
upstream a bbbb2222 done; upstream b bbbb2222 done
run; expect "a new commit starts the wait again" waiting
upstream b bbbb2222 failed
sleep 3
run; expect "an upstream deploy that failed" waiting

upstream b bbbb2222 done
rm -f "$work/www/a/metrics"
run; expect "an upstream comin that doesn't answer (held after a rollback)" waiting

upstream a bbbb2222 done
run; expect "back, but its wait starts over" waiting
sleep 3
run; expect "and then it goes" accepted

pending g3 cccc3333 old
upstream a cccc3333 done; upstream b cccc3333 done
run; sleep 3; run; expect "the older store layout for the commit" accepted

# A commit that doesn't change the upstream hosts: they stay on the old one.
pending g4 dddd4444
upstream a cccc3333 done; upstream b cccc3333 done
run; expect "a commit the upstream hosts never deploy, at first" waiting
sleep 3
run; expect "... still within the longer wait" waiting
sleep 4
run; expect "... goes after the longer wait, upstream healthy" accepted

pending g5 eeee5555
upstream a cccc3333 failed
run; sleep 7
run; expect "the longer wait doesn't pass a host whose last deploy failed" waiting
upstream a cccc3333 done; upstream b cccc3333 done 1
run; expect "nor a suspended one" waiting
upstream b cccc3333 done; rm -f "$work/www/b/metrics"
run; expect "nor one whose comin doesn't answer" waiting

if [ "$failures" -gt 0 ]; then echo "$failures failed"; exit 1; fi
echo "all passed"
