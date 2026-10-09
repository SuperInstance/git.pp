#!/bin/bash
# test-audit.sh -- the commit-reveal audit stream on a throwaway remote with the real hook.
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
J="python3 $HERE/jlog.py"; A="python3 $HERE/audit.py"

for k in casey oracle laptop; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
  git -C "$W/$1" config gpg.format ssh; git -C "$W/$1" config user.signingkey "$W/keys/$2"
  git -C "$W/$1" config user.name "$2"; git -C "$W/$1" config user.email "$2@agent"; }
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir soul questions; for k in casey oracle laptop; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3600\n' > soul/policy; printf 'Is this good?\n' > questions/root.md
for i in $(seq 1 400); do echo "item $i" > "item-$i"; done   # contents the judge will look at
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in oracle laptop casey; do clone "$b" "$b"; done
Q=$(rgit rev-parse main:questions/root.md); JU=$(printf 'name: student\n' | git hash-object --stdin)

# the judge logs 400 verdicts: items 1-200 confidently negative (suppressed), 201-400 positive
python3 - "$HERE" "$W/laptop/batch" "$Q" "$JU" <<'PY'
import sys, subprocess; sys.path.insert(0, sys.argv[1]); import jlog
out = []
for i in range(1, 401):
    s = subprocess.run(["git", "hash-object", "--stdin"], input=("item %d\n" % i).encode(), capture_output=True).stdout.decode().strip()
    p = (0.9, 0.05, 0.05) if i <= 200 else (0.05, 0.05, 0.9)
    out.append(jlog.format_line(s, sys.argv[3], sys.argv[4], p, ts="2026-10-09T06:00:00Z"))
open(sys.argv[2], "w").write("\n".join(out) + "\n")
PY

echo "1. commit, select, label, reveal, verify"
cd "$W/oracle"
yes  "oracle commits period p1"       $A commit --period p1 --auditor oracle --rate 0.25 --start 2026-10-09T00:00:00 --end 2026-10-10T00:00:00
not  "a period is committed once"     $A commit --period p1 --auditor oracle --rate 0.5
same "the seed itself is not on main" "$(rgit grep -c "$(cat .git/audit/p1.seed)" main -- . | wc -l | tr -d ' ')" 0
cd "$W/laptop"; yes "the judge logs 400 verdicts" $J append --body laptop batch
cd "$W/oracle"; out=$($A select --period p1 --auditor oracle); echo "        $out"
n=$(rgit ls-tree --name-only main inbox/ | grep -c audit-p1-)
yes  "about a quarter selected ($n of 400)" [ "$n" -ge 70 -a "$n" -le 130 ]
neg=$(for t in $(rgit ls-tree --name-only main inbox/ | grep audit-p1-); do rgit show "main:$t" | sed -n 's/^subject: //p'; done |
      python3 -c "
import sys, subprocess
neg = {subprocess.run(['git','hash-object','--stdin'], input=('item %d\n' % i).encode(), capture_output=True).stdout.decode().strip() for i in range(1, 201)}
print(sum(1 for l in sys.stdin if l.strip() in neg))")
yes  "suppressed items sampled too ($neg of $n are negative verdicts)" [ "$neg" -ge $((n/2 - n/5)) -a "$neg" -le $((n/2 + n/5)) ]
t=$(rgit ls-tree --name-only main inbox/ | grep audit-p1- | head -1)
not  "tasks are blind: no verdict in them" sh -c "git -C '$R' show 'main:$t' | grep -q '0\.9000\|0\.0500'"
yes  "tasks show the content"         sh -c "git -C '$R' show 'main:$t' | grep -q '^item [0-9]'"
yes  "tasks show the question text"   sh -c "git -C '$R' show 'main:$t' | grep -q 'Is this good?'"
same "select is idempotent"           "$($A select --period p1 --auditor oracle | sed 's/.*, //')" "0 new tasks"
yes  "oracle reveals"                 $A reveal --period p1 --auditor oracle
cd "$W/casey"; yes "anyone can verify" $A verify --period p1 --auditor oracle

echo "2. what verification catches"
cd "$W/laptop"                                       # backdated judgments after the reveal change nothing
python3 - "$HERE" "$Q" "$JU" > late <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import jlog, hashlib
for i in range(50):
    print(jlog.format_line(hashlib.sha1(b"late %d" % i).hexdigest(), sys.argv[2], sys.argv[3], (0.1, 0.1, 0.8), ts="2026-10-09T07:00:00Z"))
PY
$J append --body laptop late >/dev/null
cd "$W/casey"; yes "late, backdated lines are ignored" $A verify --period p1 --auditor oracle
cd "$W/oracle"; $A commit --period p2 --auditor oracle --rate 0.5 --start 2026-10-09T00:00:00 --end 2026-10-10T00:00:00 >/dev/null
$A reveal --period p2 --auditor oracle >/dev/null                       # revealed without ever selecting
cd "$W/casey"; out=$($A verify --period p2 --auditor oracle | tail -1)
yes  "an auditor that skipped is caught ($out)" sh -c "echo '$out' | grep -q 'FAIL: [0-9]* selected, [1-9][0-9]* skipped'"
cd "$W/oracle"; $A commit --period p3 --auditor oracle --rate 0.25 --start 2026-10-09T00:00:00 --end 2026-10-10T00:00:00 >/dev/null
$A select --period p3 --auditor oracle >/dev/null
nosel=$(python3 - "$HERE" "$(cat .git/audit/p3.seed)" "$Q" <<'PY'
import sys, subprocess; sys.path.insert(0, sys.argv[1]); import audit
for i in range(201, 401):
    s = subprocess.run(["git", "hash-object", "--stdin"], input=("item %d\n" % i).encode(), capture_output=True).stdout.decode().strip()
    if audit.key_hash(sys.argv[2], s, sys.argv[3]) >= 0.25:
        print(s); break
PY
)
python3 - "$HERE" "$nosel" "$Q" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import audit
audit.publish(".", "oracle", {"inbox/" + audit.task_name("p3", sys.argv[2], sys.argv[3]): "# hand-picked\n"}, "audit extra")
PY
$A reveal --period p3 --auditor oracle >/dev/null
cd "$W/casey"; out=$($A verify --period p3 --auditor oracle | tail -1)
yes  "an auditor that cherry-picked is caught ($out)" sh -c "echo '$out' | grep -q 'FAIL: .* [1-9][0-9]* cherry-picked'"
cd "$W/oracle"; $A commit --period p4 --auditor oracle --rate 0.25 >/dev/null
python3 - "$HERE" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import audit
audit.publish(".", "oracle", {"bodies/oracle/audit/p4.reveal": "period: p4\nseed: " + "00" * 32 + "\n"}, "audit reveal p4")
PY
cd "$W/casey"; yes "a seed swapped after the fact is caught" sh -c "$A verify --period p4 --auditor oracle | grep -q 'does not match'"
cd "$W/laptop"; not "only the auditor writes its commitments" python3 -c "
import sys; sys.path.insert(0, '$HERE'); import audit
audit.publish('.', 'laptop', {'bodies/oracle/audit/p9.commit': 'period: p9\n'}, 'forged')"

echo; echo "$pass passed, $fail failed"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
