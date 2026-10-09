#!/bin/bash
# test-audit.sh -- the audit loop end to end on a throwaway remote with the real hook: judge,
# commit-reveal audit selection, blind labels, ledger, gate, gate operator, fault drills, verification.
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
mkdir soul questions judges; for k in casey oracle laptop; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3600\naccept: default 0.10\nexplore: 0\nbypass: 0\n' > soul/policy; printf 'Is this good?\n' > questions/root.md
printf 'name: student\nkind: student\nrole: judge\n' > judges/student.md
printf 'name: casey\nkind: human\nrole: labeller\n' > judges/casey.md
for i in $(seq 1 400); do echo "item $i" > "item-$i"; done   # contents the judge will look at
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in oracle laptop casey; do clone "$b" "$b"; done
Q=$(rgit rev-parse main:questions/root.md); JU=$(rgit rev-parse main:judges/student.md); JC=$(rgit rev-parse main:judges/casey.md)

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
# p1's seed is fixed so the statistical checks below are exact, not right 99% of the time:
# it selects 109 items, 55 of them negative verdicts, 49% of those wrong (all near the expectation)
yes  "oracle commits period p1"       $A commit --period p1 --auditor oracle --rate 0.25 --seed "$(printf '33%.0s' $(seq 32))" --start 2026-10-09T00:00:00 --end 2026-10-10T00:00:00
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

echo "2. blind labels flow into the ledger and the gate"
# the truth: items 1-100 really are bad, 101-400 are good, so the judge is wrong on 101-200
cd "$W/casey"; git fetch -q origin
for t in $(rgit ls-tree --name-only main inbox/ | grep audit-p1-); do rgit show "main:$t"; echo "@@"; done > tasks
python3 - "$HERE" "$Q" "$JC" tasks > labels <<'PY'
import sys, subprocess; sys.path.insert(0, sys.argv[1]); import jlog
truth = {}
for i in range(1, 401):
    s = subprocess.run(["git", "hash-object", "--stdin"], input=("item %d\n" % i).encode(), capture_output=True).stdout.decode().strip()
    truth[s] = (1, 0, 0) if i <= 100 else (0, 0, 1)
for task in open(sys.argv[4]).read().split("@@"):
    f = dict(l.split(": ", 1) for l in task.splitlines() if l.startswith(("subject: ", "rate: ")))
    if f:
        print(jlog.format_line(f["subject"], sys.argv[2], sys.argv[3], truth[f["subject"]], "audit", float(f["rate"]),
                               seed="p1", blind="1"))
PY
yes  "the labeller logs blind labels" $J append --body casey labels
out=$(python3 - "$HERE" "$JU" "$Q" <<'PY'
import os, sys; sys.path.insert(0, sys.argv[1]); import jlog, ledger, gate
repo = os.getcwd(); jlog.git(repo, "fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main")
roles = {h: m.get("role", "judge") for h, m in ledger.manifests(repo).items()}
led = ledger.Ledger(jlog.iter_log(repo), roles)
row = led.table()[(sys.argv[2], sys.argv[3], "all")]
rec = led.gate_record(sys.argv[2], sys.argv[3])
qh = led.qhats(sys.argv[2], sys.argv[3], alpha=0.05)
neg = gate.decide((0.9, 0.05, 0.05), ["all"], rec, qh, accept=0.10)
pos = gate.decide((0.05, 0.05, 0.9), ["all"], rec, qh, accept=0.10)
n_neg, w_neg = rec[("all", -1)]; n_pos, w_pos = rec[("all", 1)]
print(row["n"], round(w_neg / n_neg, 2), w_pos, neg.action, pos.action)
PY
)
set -- $out
yes  "every label scored the judge ($1 resolved)" [ "$1" -ge 70 ]
yes  "its negative verdicts are wrong about half the time ($2)" python3 -c "assert 0.3 < $2 < 0.7"
same "its positive verdicts were never wrong" "$3" 0
same "the gate escalates new negative verdicts" "$4" escalate
same "and acts on positive ones" "$5" act

echo "2b. the gate operator: decide, log why, and escalate into a review"
cd "$W/oracle"; G="python3 $HERE/gatekeep.py --body oracle --question $Q --judge $JU"
echo "item new good" > new-good; echo "item new bad" > new-bad
pos=$($G --subject new-good --p 0.05 0.05 0.90); neg=$($G --subject new-bad --p 0.90 0.05 0.05)
yes  "acts on the verdict kind audits confirmed" sh -c "echo '$pos' | grep -q '\"action\": \"act\"'"
yes  "escalates the kind they did not"   sh -c "echo '$neg' | grep -q '\"action\": \"escalate\"'"
review=$(echo "$neg" | python3 -c "import json,sys; print(json.load(sys.stdin)['review'])")
yes  "the escalation became a review task" rgit cat-file -e "main:inbox/$review"
yes  "which shows the student's verdict" sh -c "git -C '$R' show 'main:inbox/$review' | grep -q -- '-1: 0.90'"
last=$(cd "$W/casey" && $J cat oracle | tail -2 | cut -f9,11- | tr '\t\n' '  ')
yes  "both decisions are on oracle's log with why ($last)" sh -c "echo '$last' | grep -q 'stream.*gate=act.*shadow.*gate=escalate'"

G2="python3 $HERE/gatekeep.py --body oracle"
printf '%s %s %s 0.05 0.05 0.90\n%s %s %s 0.90 0.05 0.05\n%s %s %s 0.05 0.05 0.90 src:new\n' \
  "$(echo b1 | git hash-object --stdin)" "$Q" "$JU" "$(echo b2 | git hash-object --stdin)" "$Q" "$JU" "$(echo b3 | git hash-object --stdin)" "$Q" "$JU" > batch-in
before=$(cd "$W/casey" && $J cat oracle | wc -l)
acts=$($G2 --batch batch-in | python3 -c "import json,sys; print(' '.join(json.loads(l)['action'] for l in sys.stdin))")
same "a batch decides each item on its own" "$acts" "act escalate escalate"
same "and logs them in one go"           "$(( $(cd "$W/casey" && $J cat oracle | wc -l) - before ))" 3
same "one new review per escalation"     "$(rgit ls-tree --name-only main inbox/ | grep -c review-)" 3

echo "3. fault drills: a verdict known to be wrong, shown to a reviewer"
cd "$W/oracle"; $A commit --period p5 --auditor oracle --rate 0 >/dev/null
pre=$(rgit ls-tree --name-only main inbox/ | grep review- | sort)
same "five drills from the judge's audited mistakes" "$($A drill --period p5 --auditor oracle --judge "$JU" --n 5 | cut -d' ' -f1)" 5
git fetch -q origin; post=$(rgit ls-tree --name-only main inbox/ | grep review- | sort)
drillset=$(comm -13 <(echo "$pre") <(echo "$post"))
same "they look like any review task" "$(echo "$post" | wc -l | tr -d ' ')" 8          # 5 drills + 3 escalations
d1=$(echo "$drillset" | head -1)
yes  "a drill shows the wrong verdict" sh -c "git -C '$R' show 'main:$d1' | grep -q -- '-1: 0.90'"
not  "and never says it is a drill" sh -c "git -C '$R' show 'main:$d1' | grep -qi 'drill\|p5'"
cd "$W/casey"; git fetch -q origin
for t in $drillset; do rgit show "main:$t"; echo "name: ${t#inbox/}"; echo "@@"; done > reviews
python3 - "$HERE" "$Q" "$JC" reviews > answers <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import jlog
for k, task in enumerate(t for t in open(sys.argv[4]).read().split("@@") if t.strip()):
    f = dict(l.split(": ", 1) for l in task.splitlines() if l.startswith(("subject: ", "name: ")))
    p = (0, 0, 1) if k < 3 else (1, 0, 0)          # catches the first three, follows the instrument on two
    print(jlog.format_line(f["subject"], sys.argv[2], sys.argv[3], p, "appeal", 1, review=f["name"]))
PY
$J append --body casey answers >/dev/null
cd "$W/oracle"; $A reveal --period p5 --auditor oracle >/dev/null
cd "$W/casey"; same "the drill report scores the reviewer" "$($A drills --period p5 --auditor oracle)" "casey                caught 3 of 5 drills (60%)"

echo "4. what verification catches"
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
