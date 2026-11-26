#!/bin/bash
# test-consolidate.sh -- a body's memory page: compiled from the record, verifiable, read first.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # ignore the host's own git/signing setup
mkdir -p "$W/keys" "$W/bin"; pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }
yes()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_t"; else bad "$_t"; fi; }
not()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then bad "$_t"; else ok "$_t"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        want: %s\n        got:  %s\n' "$3" "$2"; fi; }
has()  { grep -qxF -- "$2" "$1"; }
R="$W/remote.git"; rgit() { git -C "$R" "$@"; }
C="python3 $HERE/consolidate.py"; F="python3 $HERE/forecast.py"

for k in casey laptop oracle; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
  git -C "$W/$1" config gpg.format ssh; git -C "$W/$1" config user.signingkey "$W/keys/$2"
  git -C "$W/$1" config user.name "$2"; git -C "$W/$1" config user.email "$2@agent"; }
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir -p soul judges questions inbox
for k in casey laptop oracle; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3600\n' > soul/policy
printf 'name: laptop-agent\nkind: llm\nrole: judge\n' > judges/laptop-agent.md
printf 'name: ci\nkind: world\nrole: world\n' > judges/ci.md
printf 'Is this good?\n' > questions/root.md
printf '# Rotate the key\n' > inbox/001-ok; printf '# Migrate the disk\n' > inbox/002-bad
cp "$HERE/tick.sh" .
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in laptop oracle; do clone "$b" "$b"; done
AG=$(rgit rev-parse main:judges/laptop-agent.md); CI=$(rgit rev-parse main:judges/ci.md); Q=$(rgit rev-parse main:questions/root.md)
printf '#!/bin/sh\necho rotated > "$2/answer"\n' > "$W/bin/ok"
printf '#!/bin/sh\necho copying\necho "disk full at 93%%"\nexit 3\n' > "$W/bin/fail"; chmod +x "$W/bin/"*
tick() { ( cd "$W/laptop" && AGENT_ID=laptop CAPS=cpu EXEC="$1" sh ./tick.sh ); }

echo "1. a body's history"
tick "$W/bin/ok"; tick "$W/bin/fail"
same "both tasks are done"            "$(rgit ls-tree --name-only main:done | tr '\n' ' ')" "001-ok 002-bad "
cd "$W/laptop"; git pull -q
echo rotated > made.md; $F make --body laptop --judge "$AG" --made made.md --criterion "the key works" --p 0.9 >/dev/null
S=$(printf 'plan' | git hash-object --stdin)
python3 - "$HERE" "$S" "$Q" "$AG" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); import jlog
s, q, ag = sys.argv[2:5]
jlog.append(os.getcwd(), "laptop", [jlog.format_line(s, q, ag, (0.05, 0.05, 0.9), gate="act", regions="all", cfg="x")])
PY
cd "$W/oracle"
$F resolve --body oracle --judge "$CI" --forecast bodies/laptop/forecasts/made.md --outcome yes >/dev/null
python3 - "$HERE" "$S" "$Q" "$CI" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); import jlog
s, q, ci = sys.argv[2:5]
jlog.append(os.getcwd(), "oracle", [jlog.format_line(s, q, ci, (1, 0, 0), outcome="no")])
PY

echo "2. the memory page"
cd "$W/laptop"
same "published"                      "$($C publish --body laptop)" "bodies/laptop/memory.md"
rgit show main:bodies/laptop/memory.md > m.md
yes  "counts the record"              has m.md "2 tasks finished, 1 failed."
yes  "failure first, with its last log line" sh -c "grep -A1 '^- 002-bad' m.md | tail -1 | grep -qxF '  last log line: \`disk full at 93%\`' && grep -n '^- 00' m.md | head -1 | grep -q 002-bad"
yes  "then the success"               has m.md "- 001-ok: done: Rotate the key"
yes  "the forecast and its resolution" has m.md "- made: said 0.90, world said yes (Brier 0.020)"
yes  "what the gate did"              has m.md "act 1"
yes  "where the world corrected it"   has m.md "- laptop-agent said +1 about $(echo "$S" | cut -c1-12); resolved -1"
same "nothing new: nothing published" "$($C publish --body laptop)" "unchanged"

echo "3. anyone can check it"
cd "$W/oracle"
yes  "verify recomputes it"           $C verify --body laptop
cd "$W/seed"; git pull -q; sed -i 's/^2 tasks finished, 1 failed\.$/2 tasks finished, 0 failed./' bodies/laptop/memory.md
git commit -qS -a -m "kinder memory"; git push -q origin main
cd "$W/oracle"
not  "an edited page does not verify" $C verify --body laptop
same "and says so"                    "$($C verify --body laptop)" "MISMATCH: bodies/laptop/memory.md does not follow from its pins"

echo "4. the window reads it first"
cd "$W/laptop"; git pull -q; $C publish --body laptop >/dev/null
printf '# Rotate another key\n' > task.md
python3 "$HERE/window.py" task.md --agent laptop > w.md
yes  "memory before the task"         sh -c "grep -n '^## ' w.md | head -2 | tr '\n' ' ' | grep -q '## Memory.*## Task'"
yes  "its sections nest under it"     has w.md "### Record"
yes  "with the failure"               has w.md "2 tasks finished, 1 failed."

echo; echo "$pass passed, $fail failed"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
