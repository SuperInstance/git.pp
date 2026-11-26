#!/bin/bash
# test-ops.sh -- runs every "# [machine]" shell block in OPERATIONS.md, in order, each machine
# with its own HOME, so the operations guide cannot drift from what works.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GITPP="$HERE"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok    $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }

python3 - "$HERE/OPERATIONS.md" "$W" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
blocks = re.findall(r"```sh\n# \[(\w+)\] ([^\n]*)\n(.*?)```", text, re.S)
for i, (who, title, body) in enumerate(blocks):
    open("%s/step-%02d-%s" % (sys.argv[2], i, who), "w").write("# %s\n%s" % (title, body))
PY

for step in "$W"/step-*; do
  who=${step##*-}; title=$(head -1 "$step" | cut -c3-)
  home="$W/home-$who"; mkdir -p "$home"
  remote="$W/home-oracle/fleet.git"
  # glue a real fleet does by hand: bodies send their public keys to the owner
  case $title in admit*) for b in oracle laptop; do cp "$W/home-$b/.ssh/fleet.pub" "$W/home-casey/$b.pub"; done ;; esac
  if out=$(cd "$home" && HOME="$home" REMOTE="$remote" bash -e "$step" 2>&1); then
    ok "[$who] $title"
  else
    bad "[$who] $title"; echo "$out" | sed 's/^/        /' | tail -8
  fi
  case $title in
    "read the result"*) [ "$(echo "$out" | head -1)" = "hello, fleet" ] && ok "  the agent's answer arrived" || bad "  the agent's answer arrived ($out)"
                        echo "$out" | grep -q '^Window: [0-9a-f]\{40\}' && ok "  the done commit names its window" || bad "  the done commit names its window" ;;
    "move the local"*)  [ "$(echo "$out" | tail -1)" = "up to date" ] && ok "  the second sync appends nothing" || bad "  the second sync appends nothing" ;;
    "verify the auditor"*) echo "$out" | grep -q '^ok: 1 selected' && ok "  the audit selected the one judged item and verified" || bad "  audit verify ($out)" ;;
    "gate a batch"*)    echo "$out" | grep -q '"action": "escalate"' && echo "$out" | grep -q '"review": "review-' && ok "  an unaudited judge escalates to a review task" || bad "  gate ($out)" ;;
    "tick: the agent judges"*) echo "$out" | tail -1 | grep -q '"action": "escalate"' && ok "  the agent's judgment went through the gate" || bad "  exec gate ($out)" ;;
    "consolidate memory"*) echo "$out" | grep -q '^ok: bodies/laptop/memory.md follows from main@' && ok "  the memory page verifies" || bad "  memory verify ($out)"
                        echo "$out" | grep -q '^1 task finished, 0 failed.$' && echo "$out" | grep -q '^- hello: said 0.90, world said yes (Brier 0.020)$' \
                          && ok "  it records the task and the resolved forecast" || bad "  memory content ($out)" ;;
    "resolve the forecast"*) [ "$(echo "$out" | head -1)" = "bodies/laptop/forecasts/hello.md" ] && ok "  the forecast was open" || bad "  forecast open ($out)"
                        [ "$(echo "$out" | tail -1 | tr -d ' ')" = 0 ] && ok "  and is resolved" || bad "  forecast resolved ($out)" ;;
  esac
done

echo; echo "$pass passed, $fail failed  ($(ls "$W"/step-* | wc -l | tr -d ' ') blocks from OPERATIONS.md)"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
