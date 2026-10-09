#!/bin/bash
# test-forecast.sh -- an agent's commitments as forecasts, resolved by the world, scored by the ledger.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # ignore the host's own git/signing setup
mkdir -p "$W/keys"; pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }
yes()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_t"; else bad "$_t"; fi; }
not()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then bad "$_t"; else ok "$_t"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        want: %s\n        got:  %s\n' "$3" "$2"; fi; }
R="$W/remote.git"; rgit() { git -C "$R" "$@"; }
F="python3 $HERE/forecast.py"

for k in casey laptop oracle; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
  git -C "$W/$1" config gpg.format ssh; git -C "$W/$1" config user.signingkey "$W/keys/$2"
  git -C "$W/$1" config user.name "$2"; git -C "$W/$1" config user.email "$2@agent"; }
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir soul judges; for k in casey laptop oracle; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3600\n' > soul/policy
printf 'name: laptop-agent\nkind: llm\nrole: judge\n' > judges/laptop-agent.md
printf 'name: ci\nkind: world\nrole: world\n' > judges/ci.md
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in laptop oracle; do clone "$b" "$b"; done
AG=$(rgit rev-parse main:judges/laptop-agent.md); CI=$(rgit rev-parse main:judges/ci.md)

echo "1. the agent commits to forecasts"
cd "$W/laptop"
for i in 1 2 3 4; do echo "draft $i" > "made-$i.md"; done
for i in 1 2 3 4; do $F make --body laptop --judge "$AG" --made "made-$i.md" --criterion "the reader can act on it without asking" --p 0.9 >/dev/null; done
same "four forecasts on main"          "$(rgit ls-tree --name-only main bodies/laptop/forecasts/ | wc -l | tr -d ' ')" 4
yes  "each names what it resolves"     sh -c "git -C '$R' show main:bodies/laptop/forecasts/made-1.md | grep -q 'act on it without asking'"
not  "a forecast is never rewritten"   $F make --body laptop --judge "$AG" --made made-1.md --criterion "easier" --p 0.99
same "all four are open"               "$(cd "$W/oracle" && $F open | wc -l | tr -d ' ')" 4

echo "2. the world resolves them; the agent is scored"
cd "$W/oracle"
not  "an ordinary judge cannot resolve" $F resolve --body oracle --judge "$AG" --forecast bodies/laptop/forecasts/made-1.md --outcome yes
for i in 1 2; do $F resolve --body oracle --judge "$CI" --forecast "bodies/laptop/forecasts/made-$i.md" --outcome yes >/dev/null; done
for i in 3 4; do $F resolve --body oracle --judge "$CI" --forecast "bodies/laptop/forecasts/made-$i.md" --outcome no >/dev/null; done
same "nothing is open"                 "$($F open | wc -l | tr -d ' ')" 0
brier=$(python3 - "$HERE" "$AG" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); import jlog, ledger
repo = os.getcwd(); jlog.git(repo, "fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main")
led = ledger.Ledger(jlog.iter_log(repo), ledger.roles_of(ledger.manifests(repo)))
rows = [v for (j, q, r), v in led.table().items() if j == sys.argv[2] and r == "all"]
print(len(rows), round(sum(v["brier"] * v["n"] for v in rows) / sum(v["n"] for v in rows), 3))
PY
)
same "the agent's track record: 4 resolved, mean Brier (0.02*2 + 1.62*2)/4" "$brier" "4 0.82"

echo; echo "$pass passed, $fail failed"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
