#!/bin/bash
# test-window.sh -- the window compiler: sections, judgments, open questions, precedents, pins.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # ignore the host's own git/signing setup
mkdir -p "$W/keys"; pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }
yes()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_t"; else bad "$_t"; fi; }
not()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then bad "$_t"; else ok "$_t"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        want: %s\n        got:  %s\n' "$3" "$2"; fi; }
has()  { grep -qF -- "$2" "$1"; }
R="$W/remote.git"; rgit() { git -C "$R" "$@"; }
J="python3 $HERE/jlog.py"; WIN="python3 $HERE/window.py"

for k in casey laptop oracle; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
  git -C "$W/$1" config gpg.format ssh; git -C "$W/$1" config user.signingkey "$W/keys/$2"
  git -C "$W/$1" config user.name "$2"; git -C "$W/$1" config user.email "$2@agent"; }
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir -p soul judges questions/safe done/001-fix done/002-bad bodies/laptop
for k in casey laptop oracle; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3600\n' > soul/policy
printf 'name: student\nrole: judge\n' > judges/student.md; printf 'name: big\nrole: judge\n' > judges/big.md
printf 'Is this good?\n' > questions/root.md; printf 'Can this be undone?\n' > questions/safe/reversible.md
printf 'rotate the uno key\n' > done/001-fix/task; printf 'rotated; old key revoked\n' > done/001-fix/result.md; echo 0 > done/001-fix/status
printf 'rotate the kimi key\n' > done/002-bad/task; printf 'half rotated, kimi locked out\n' > done/002-bad/result.md; echo 75 > done/002-bad/status
printf 'You keep keys rotated without locking anyone out.\n' > bodies/laptop/charter.md
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in laptop oracle; do clone "$b" "$b"; done
Q=$(rgit rev-parse main:questions/root.md); ST=$(rgit rev-parse main:judges/student.md); BG=$(rgit rev-parse main:judges/big.md)
cat > "$W/task.md" <<'TASK'
# Rotate the laptop key
Do what done/001-fix/result.md did, and avoid what happened in done/002-bad/result.md.
TASK
T=$(git hash-object "$W/task.md")
v2() { python3 -c "import sys; sys.path.insert(0, '$HERE'); import jlog; print(jlog.format_line(sys.argv[1], sys.argv[2], sys.argv[3], [float(x) for x in sys.argv[4:7]]))" "$@"; }
cd "$W/oracle"; { v2 "$T" "$Q" "$ST" 0.45 0.10 0.45; v2 "$T" "$Q" "$BG" 0.05 0.05 0.90; } > j; $J append --body oracle j >/dev/null

echo "1. sections"
cd "$W/laptop"; $WIN "$W/task.md" --agent laptop > w1.md
yes  "header pins main and every log"  has w1.md "main@$(rgit rev-parse main | cut -c1-12) · oracle@$(rgit rev-parse refs/log/judgments/oracle | cut -c1-12)"
yes  "the agent's charter comes first"  has w1.md "You keep keys rotated without locking anyone out."
yes  "the task, verbatim"               has w1.md "avoid what happened in done/002-bad/result.md"
yes  "the student's conflict"           has w1.md "| student | 0.45 | 0.10 | 0.45 | conflict, judges disagree |"
yes  "the big model's verdict"          has w1.md "| big | 0.05 | 0.05 | 0.90 | settled +, judges disagree |"
yes  "disagreement is an open question" has w1.md "questions/root.md about $(echo $T | cut -c1-12): judges disagree"
yes  "and so is the never-asked one"    has w1.md "never asked of this task: questions/safe/reversible.md"
yes  "precedents, failure first"        sh -c "grep -n '^- 00[12]' w1.md | head -1 | grep -q '002-bad: failed (status 75)'"
yes  "and the success"                  has w1.md "- 001-fix: done; linked by done/001-fix/result.md (named in the task)"

echo "2. pins make it reproducible"
pins=$(sed -n 3p w1.md); at=$(echo "$pins" | sed 's/^main@\([0-9a-f]*\) .*/\1/'); tip=$(rgit rev-parse refs/log/judgments/oracle)
cd "$W/oracle"; v2 "$T" "$Q" "$ST" 0.05 0.05 0.90 > j2; $J append --body oracle j2 >/dev/null
cd "$W/laptop"; $WIN "$W/task.md" --agent laptop > w2.md
not  "new judgments change the window"  cmp -s w1.md w2.md
$WIN "$W/task.md" --agent laptop --at "$at" --tips "oracle=$tip" > w3.md
yes  "the old pins reproduce it byte for byte" cmp -s w1.md w3.md
cd "$W/oracle"; $WIN "$W/task.md" --agent laptop --at "$at" --tips "oracle=$tip" > w4.md
yes  "on a second body too"             cmp -s "$W/laptop/w1.md" w4.md
cd "$W/laptop"; $WIN "$W/task.md" --agent laptop --budget 1 > w5.md
yes  "a tight budget says what it cut"  has w5.md "more precedents"

echo; echo "$pass passed, $fail failed"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
