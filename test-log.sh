#!/bin/bash
# test-log.sh -- judgment logs on a throwaway remote: jlog.py writes, pre-receive enforces.
#   ./test-log.sh       (AWK=gawk|mawk|"busybox awk" selects the awk the hook runs)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); export AWK="${AWK:-awk}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # ignore the host's own git/signing setup
mkdir -p "$W/keys"; pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }
yes()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_t"; else bad "$_t"; fi; }
not()  { _t=$1; shift; if "$@" >/dev/null 2>&1; then bad "$_t"; else ok "$_t"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        want: %s\n        got:  %s\n' "$3" "$2"; fi; }
R="$W/remote.git"; rgit() { git -C "$R" "$@"; }
J="python3 $HERE/jlog.py"

for k in casey oracle laptop mallory; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
  git -C "$W/$1" config gpg.format ssh; git -C "$W/$1" config user.signingkey "$W/keys/$2"
  git -C "$W/$1" config user.name "$2"; git -C "$W/$1" config user.email "$2@agent"; }
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir soul; for k in casey oracle laptop; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3600\n' > soul/policy; echo "# protocol" > PROTOCOL.md
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in oracle laptop mallory; do clone "$b" "$b"; done
MAIN=$(rgit rev-parse main)

h() { printf '%s' "$1" | git hash-object --stdin; }
S1=$(h "first subject"); S2=$(h "second subject"); Q=$(h "Is this good?"); JU=$(h "name: student")
v2() { python3 -c "import sys; sys.path.insert(0, '$HERE'); import jlog; print(jlog.format_line(*sys.argv[1:4], [float(x) for x in sys.argv[4:7]], sys.argv[7], float(sys.argv[8])))" "$@"; }
L1=$(v2 "$S1" "$Q" "$JU" 0.02 0.11 0.87 stream 1)
L2=$(v2 "$S2" "$Q" "$JU" 0.46 0.09 0.45 audit 0.05)
L0=$(printf '2026-10-07T08:00:00\t%s\t%s\tintuition-student-v1\t0.0400\t0.1100\t0.8500' "$S1" "$Q")
logtip() { rgit rev-parse -q --verify "refs/log/judgments/$1"; }
lines() { (cd "$W/$1" && $J cat "${@:2}") | wc -l | tr -d ' '; }

echo "1. a body appends to its own log"
cd "$W/oracle"
yes  "oracle appends a v2 batch"      sh -c "printf '%s\n%s\n' '$L1' '$L2' | $J append --body oracle"
yes  "the log ref exists on the remote" logtip oracle
same "signed by oracle"               "$(rgit -c gpg.ssh.allowedSignersFile="$W/seed/soul/allowed_signers" log -1 --format=%GS refs/log/judgments/oracle)" oracle
same "one batch file, nothing else"   "$(rgit ls-tree -r --name-only refs/log/judgments/oracle | grep -c '^20[0-9][0-9]/[01][0-9]/[0-3][0-9]/[0-9]*\.tsv$')" 1
yes  "a v0 line is still accepted"    sh -c "printf '%s\n' '$L0' | $J append --body oracle"
same "two batches"                    "$(rgit ls-tree -r --name-only refs/log/judgments/oracle | wc -l | tr -d ' ')" 2
same "main is untouched"              "$(rgit rev-parse main)" "$MAIN"
cd "$W/laptop"; yes "laptop appends its own" sh -c "printf '%s\n' '$L2' | $J append --body laptop"
same "cat reads every body, in order" "$(cd "$W/laptop" && $J cat | cut -f1,3 | tr '\t\n' ': ')" "laptop:$S2 oracle:$S1 oracle:$S2 oracle:$S1 "
same "cat can pick one body"          "$(lines laptop oracle)" 3

echo "2. what the hook refuses"
cd "$W/laptop"; T=$(logtip oracle)
not  "laptop writing oracle's log"    sh -c "printf '%s\n' '$L1' | $J append --body oracle"
cd "$W/mallory"; not "an unknown key" sh -c "printf '%s\n' '$L1' | $J append --body mallory"
same "oracle's log unchanged"         "$(logtip oracle)" "$T"
cd "$W/oracle"; git fetch -q origin '+refs/log/judgments/*:refs/log/judgments/*'
commit() { git commit-tree -S "$@"; }                     # signed by oracle (this clone's key)
idx() { rm -f "$W/i"; GIT_INDEX_FILE="$W/i" git read-tree "$1"; }
f1=$(git ls-tree -r --name-only "$T" | head -1)
idx "$T"; GIT_INDEX_FILE="$W/i" git update-index --cacheinfo "100644,$(printf '%s\n' "$L2" | git hash-object -w --stdin),$f1"
not  "editing a batch"                git push -q origin "$(commit -p "$T" -m edit "$(GIT_INDEX_FILE="$W/i" git write-tree)"):refs/log/judgments/oracle"
idx "$T"; GIT_INDEX_FILE="$W/i" git update-index --force-remove "$f1"
not  "deleting a batch"               git push -q origin "$(commit -p "$T" -m delete "$(GIT_INDEX_FILE="$W/i" git write-tree)"):refs/log/judgments/oracle"
not  "rewriting history"              git push -q -f origin "$(commit -m rewritten "$(git rev-parse "$T^{tree}")"):refs/log/judgments/oracle"
not  "deleting the log"               git push -q origin :refs/log/judgments/oracle
idx "$T"; GIT_INDEX_FILE="$W/i" git update-index --add --cacheinfo "100644,$(echo note | git hash-object -w --stdin),notes.md"
not  "a file that is not a .tsv batch" git push -q origin "$(commit -p "$T" -m note "$(GIT_INDEX_FILE="$W/i" git write-tree)"):refs/log/judgments/oracle"
idx "$(git rev-parse origin/main)"; GIT_INDEX_FILE="$W/i" git update-index --add --cacheinfo "100644,$(printf '%s\n' "$L1" | git hash-object -w --stdin),2026/10/09/000000.tsv"
not  "a log grown out of main's history" git push -q origin "$(commit -p origin/main -m sneaky "$(GIT_INDEX_FILE="$W/i" git write-tree)"):refs/log/judgments/oracle2"
idx "$T"; GIT_INDEX_FILE="$W/i" git update-index --add --cacheinfo "100644,$(printf '%s\r\n' "$L1" | git hash-object -w --stdin),2026/10/09/000001.tsv"
not  "a stored batch with CRLF endings" git push -q origin "$(commit -p "$T" -m crlf "$(GIT_INDEX_FILE="$W/i" git write-tree)"):refs/log/judgments/oracle"
same "oracle's log still unchanged"   "$(logtip oracle)" "$T"
same "main still untouched"           "$(rgit rev-parse main)" "$MAIN"

echo "3. the hook and jlog.py agree on every line"
TAB=$(printf '\t'); ts=2026-10-09T05:00:00Z
cases="ok|$L1
ok|$L2
ok|$L0
ok|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.3333${TAB}0.3333${TAB}0.3334${TAB}explore${TAB}0.01${TAB}cfg=abc${TAB}blind=1
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.5${TAB}0.5
no|not-a-time$TAB$S1$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}stream${TAB}1
no|$ts${TAB}abc123$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}stream${TAB}1
no|$ts$TAB$S1$TAB$Q${TAB}student-name${TAB}0.1${TAB}0.1${TAB}0.8${TAB}stream${TAB}1
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.2${TAB}0.2${TAB}0.8${TAB}stream${TAB}1
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}-0.1${TAB}0.3${TAB}0.8${TAB}stream${TAB}1
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}guess${TAB}1
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}audit${TAB}0
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}audit${TAB}1.5
no|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}stream${TAB}1${TAB}Bad=1
ok|$ts$TAB$S1$TAB$Q$TAB$JU${TAB}0.1${TAB}0.1${TAB}0.8${TAB}stream${TAB}1$(printf '\r')
no|"
cd "$W/laptop"; agree=0; total=0; disagree=""
while IFS= read -r c; do
  want=${c%%|*}; line=${c#*|}; total=$((total+1))
  py=$(printf '%s\n' "$line" | $J validate >/dev/null 2>&1 && echo ok || echo no)
  [ -z "$line" ] && py=no                                     # an empty batch is refused by both
  hook=$(printf '%s\n' "$line" | $J append --body laptop --no-validate >/dev/null 2>&1 && echo ok || echo no)
  [ "$py" = "$want" ] && [ "$hook" = "$want" ] && agree=$((agree+1)) || disagree="$disagree [$total want=$want py=$py hook=$hook]"
done <<EOF
$cases
EOF
same "all $total cases agree$disagree" "$agree" "$total"

echo; echo "$pass passed, $fail failed  (awk=$AWK)"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
