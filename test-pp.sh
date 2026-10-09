#!/bin/bash
# test-pp.sh -- runs the real tick and hooks on a throwaway remote, then checks the derived views.
#   ./test-pp.sh        (AWK=gawk|mawk|"busybox awk" and SH=dash|bash select the implementations used)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); export WORLD="$W/world" SH=${SH:-sh} AWK="${AWK:-awk}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # ignore the host's own git/signing setup
mkdir -p "$WORLD" "$W/keys" "$W/bin"; pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok    $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }
yes()  { n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
not()  { n=$1; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '        want: %s\n        got:  %s\n' "${3//$'\n'/ | }" "${2//$'\n'/ | }"; fi; }
R="$W/remote.git"
rgit()  { git -C "$R" "$@"; }
ls_v()  { rgit ls-tree -r --name-only "refs/pp/$1"; }                       # every address in a view
nx()    { echo "refs/pp/by-hash:${1%"${1#??}"}/${1#??}"; }                     # where a hash lives in the nexus
src()   { rgit log -1 --format=%B "refs/pp/$1" | sed -n 's/^Source: //p'; }
subj()  { rgit log -1 --format=%s "$(echo "$1" | sed 's/^[0-9]*-\([0-9a-f]*\).*/\1/')"; }   # 000012-abc.../x -> that commit's subject

# --- world: keys, genesis with soul/axes + project.sh, both hooks, three bodies ------------------
for k in casey oracle laptop kimi; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
  git -C "$W/$1" config gpg.format ssh; git -C "$W/$1" config user.signingkey "$W/keys/$2"
  git -C "$W/$1" config user.name "$2"; git -C "$W/$1" config user.email "$2@agent"; }
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir soul; for k in casey oracle laptop kimi; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 99999\n' > soul/policy
cp "$HERE/soul/axes" soul/axes; cp "$HERE/tick.sh" "$HERE/project.sh" .; echo "# protocol" > PROTOCOL.md
git add -A; git commit -qS -m genesis; git push -q origin main
for h in pre-receive post-receive; do cp "$HERE/$h" "$R/hooks/$h"; chmod +x "$R/hooks/$h"; done
for b in oracle laptop kimi; do clone "$b" "$b"; clone "x-$b" "$b"; done; clone x-casey casey

tick()  { b=$1; shift; ( cd "$W/$b" && env AGENT_ID="$b" "$@" "$SH" ./tick.sh ); }
fresh() { cd "$W/x-$1" && git fetch -q origin && git checkout -qfB main origin/main && git clean -qfdx; }
push()  { git add -A && git commit -qS -m "${1:-x}" && git push -q origin HEAD:main; }
task()  { fresh casey; mkdir -p inbox; printf '%s\n' "$2" > "inbox/$1"; push "task $1"; }
exe()   { printf '#!/bin/sh\n%s\n' "$2" > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
exe echo   'echo "hello from $AGENT_ID" > "$2/answer"'
exe notify '$SH "$TICK" effect notify -- echo sent > "$2/reply"'

# one task in each state: done, done with an effect ledger, claimed mid-effect, waiting
task 001-hello "say hello";   tick oracle CAPS=cpu EXEC="$W/bin/echo"
task 002-notify "tell them";  tick laptop CAPS=cpu EXEC="$W/bin/notify"
task 003-pay "pay them";      fresh laptop; mkdir -p claimed/laptop; git mv inbox/003-pay claimed/laptop/; push "claim 003-pay"
mkdir -p claimed/laptop/003-pay.fx; echo "pay" > claimed/laptop/003-pay.fx/pay.intent; push "intent 003-pay/pay"
task 004-render "$(printf 'needs: gpu\nrender')"; tick kimi CAPS=cpu
TIP=$(rgit rev-parse main)

echo "1. the views exist, and nobody had to ask for them"
same "three views, all of the tip"   "$(for v in by-body by-hash by-task; do src $v; done | uniq -c | tr -s ' ')" " 3 $TIP"
git clone -q "$R" "$W/plain"
same "a plain clone never sees them" "$(git -C "$W/plain" for-each-ref | grep -c pp)" 0
yes  "its tree is still just files"  test -f "$W/plain/inbox/004-render"

echo "2. by-task: the same cells, addressed task-first"
same "exact listing" "$(ls_v by-task)" "001-hello/done/answer
001-hello/done/log
001-hello/done/status
001-hello/done/task
002-notify/done/fx/notify.intent
002-notify/done/fx/notify.result
002-notify/done/log
002-notify/done/reply
002-notify/done/status
002-notify/done/task
003-pay/claimed/laptop/fx/pay.intent
003-pay/claimed/laptop/task
004-render/inbox/task"
same "a cell is the very same blob"  "$(rgit rev-parse refs/pp/by-task:004-render/inbox/task)" "$(rgit rev-parse main:inbox/004-render)"
blobs() { rgit rev-list --objects "$@" | cut -d' ' -f1 | rgit cat-file --batch-check | awk '$2 == "blob" { print $1 }' | sort -u; }
same "views add no blobs at all"     "$(comm -23 <(blobs refs/pp/by-task refs/pp/by-body refs/pp/by-hash) <(blobs main) | wc -l | tr -d ' ')" 0

echo "3. by-body: the same cells again, body-first"
same "exact listing" "$(ls_v by-body)" "kimi/self/manifest
laptop/claimed/003-pay/fx/pay.intent
laptop/claimed/003-pay/task
laptop/self/manifest
oracle/self/manifest"

echo "4. by-hash: the nexus (hash -> every commit and path where that content appeared)"
h=$(rgit rev-parse main:done/001-hello/task); life=$(rgit ls-tree -r --name-only "$(nx "$h")")
same "one task file, three addresses" "$(echo "$life" | cut -d/ -f2-)" "inbox/001-hello
claimed/oracle/001-hello
done/001-hello/task"
same "each stamped with its commit"  "$(echo "$life" | while read -r l; do subj "$l"; done)" "task 001-hello
claim 001-hello
done 001-hello"
h=$(rgit rev-parse main:done/001-hello/status)
same "shared content is one point"   "$(rgit ls-tree -r --name-only "$(nx "$h")" | cut -d/ -f2-)" "done/001-hello/status
done/002-notify/status"
h=$(rgit rev-parse main:PROTOCOL.md)
same "paths with no family are there" "$(rgit ls-tree -r --name-only "$(nx "$h")" | cut -d/ -f2-)" "PROTOCOL.md"
same "every blob in history is a key" "$(rgit ls-tree -r -d --name-only refs/pp/by-hash | awk -F/ 'NF == 2' | tr -d / | sort)" "$(blobs main)"

echo "5. a second body recomputes the same hashes"
want=$(rgit for-each-ref --format='%(refname:lstrip=2) %(objectname)' refs/pp/)
sleep 1; tick kimi CAPS=cpu          # kimi's own tick verifies main and pins refs/verified/main
same "kimi builds identical commits" "$(cd "$W/kimi" && $SH ./project.sh build)" "$want"
yes  "kimi: verify passes"           sh -c "cd '$W/kimi' && $SH ./project.sh verify origin"
yes  "a human clone can verify too"  sh -c "cd '$W/plain' && $SH ./project.sh verify origin"
same "rebuilding is idempotent"      "$(cd "$R" && $SH "$W/kimi/project.sh" build)" "$want"
not  "an older commit differs"       [ "$(cd "$W/kimi" && $SH ./project.sh build main~2)" = "$want" ]
( cd "$W/plain" && git fetch -q origin 'refs/pp/*:refs/pp/*' && git worktree add -q "$W/pivot" refs/pp/by-task ) 2>/dev/null
same "plain git reads a view"        "$(git -C "$W/plain" show refs/pp/by-task:001-hello/done/answer)" "hello from oracle"
yes  "a view checks out as a folder" test -f "$W/pivot/003-pay/claimed/laptop/fx/pay.intent"
for a in gawk mawk "busybox awk"; do command -v ${a%% *} >/dev/null || continue
  same "same hashes under $a"        "$(cd "$W/kimi" && AWK="$a" $SH ./project.sh build)" "$want"; done

echo "6. forged views are caught; pushing views is refused"
forge() { # forge <view> <path> <blob> <source>: a view that differs in one cell but is otherwise well-formed
  i="$W/forge.idx"; rm -f "$i"; GIT_INDEX_FILE="$i" rgit read-tree "refs/pp/$1"
  GIT_INDEX_FILE="$i" rgit update-index --add --cacheinfo "100644,$3,$2"; t=$(GIT_INDEX_FILE="$i" rgit write-tree)
  d="$(rgit log -1 --format=%ct "$4") +0000"
  rgit update-ref "refs/pp/$1" "$(printf 'pp/%s\n\nSource: %s\n' "$1" "$4" | GIT_AUTHOR_NAME=pp GIT_AUTHOR_EMAIL=pp@agent \
    GIT_COMMITTER_NAME=pp GIT_COMMITTER_EMAIL=pp@agent GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" rgit commit-tree "$t")"; }
forge by-task 004-render/inbox/task "$(rgit rev-parse main:done/001-hello/task)" "$TIP"
out=$(cd "$W/kimi" && $SH ./project.sh verify origin 2>&1); rc=$?
same "one swapped cell fails verify" "$rc ${out%%:*}" "1 MISMATCH by-task"
( cd "$R" && $SH "$W/kimi/project.sh" >/dev/null ); rgit update-ref refs/pp/extra refs/pp/by-task
same "an undeclared view fails"      "$(cd "$W/kimi" && $SH ./project.sh verify origin 2>&1 | head -1)" "UNDECLARED extra"
rgit update-ref -d refs/pp/extra; rgit update-ref -d refs/pp/by-body
same "a missing view fails"          "$(cd "$W/kimi" && $SH ./project.sh verify origin 2>&1 | head -1)" "MISSING by-body"
# a source that is not on main, carrying a projector that would run if verify trusted it
cd "$W/x-kimi"; git fetch -q origin; git checkout -qfB evil origin/main
printf '#!/bin/sh\ntouch "$WORLD/pwned"\n' > project.sh; git add -A; git commit -qS -m evil; E=$(git rev-parse HEAD)
git push -q "$R" HEAD:refs/heads/evil 2>/dev/null
not  "(pre-receive refuses the branch)" rgit rev-parse -q --verify refs/heads/evil
git -C "$R" fetch -q "$W/x-kimi" evil; git -C "$W/kimi" fetch -q "$W/x-kimi" evil      # so smuggle the objects in directly
( cd "$R" && $SH "$W/kimi/project.sh" >/dev/null )
for v in by-task by-body by-hash; do forge $v zz "$(rgit rev-parse main:PROTOCOL.md)" "$E"; done
not  "a source off main is refused"  sh -c "cd '$W/kimi' && $SH ./project.sh verify origin"
not  "and its projector never ran"   test -e "$WORLD/pwned"
( cd "$R" && $SH "$W/kimi/project.sh" >/dev/null )
yes  "republished, verify passes"    sh -c "cd '$W/kimi' && $SH ./project.sh verify origin"
fresh kimi
not  "a body cannot push a view"     git push -q origin HEAD:refs/pp/by-task

echo "7. views are data: one line in soul/axes"
fresh casey; echo "view life  task seq state body part effect" >> soul/axes; push "add view life"
same "a new pivot appears"           "$(ls_v life | grep '^001-hello' | cut -d/ -f1,3- | tr '\n' ' ')" \
  "001-hello/inbox/task 001-hello/claimed/oracle/task 001-hello/done/answer 001-hello/done/log 001-hello/done/status 001-hello/done/task "
fresh casey; sed -i '/^view by-body/d' soul/axes; push "drop view by-body"
not  "a dropped view's ref is removed" rgit rev-parse -q --verify refs/pp/by-body
yes  "still verifiable"              sh -c "cd '$W/plain' && git fetch -q origin && $SH ./project.sh verify origin"

echo "8. a view that is not one-to-one is refused whole"
before=$(rgit for-each-ref refs/pp/)
fresh casey; echo "view flat  state" >> soul/axes; msg=$(push "add a bad view" 2>&1)
yes  "the pusher is told why"        sh -c "echo '$msg' | grep -q 'both land on'"
yes  "the push itself still lands"   [ "$(rgit log -1 --format=%s main)" = "add a bad view" ]
same "no view moved"                 "$(rgit for-each-ref refs/pp/)" "$before"
same "verify reports them as behind" "$(cd "$W/plain" && git fetch -q origin && $SH ./project.sh verify origin | sed 's/.*(//')" "1 behind main)"
fresh casey; sed -i '/^view flat/d' soul/axes; echo "view tangle  body task effect" >> soul/axes; msg=$(push "add another bad view" 2>&1)
yes  "file-vs-folder clashes too"    sh -c "echo '$msg' | grep -q 'both a file and a directory'"
same "still no view moved"           "$(rgit for-each-ref refs/pp/)" "$before"
fresh casey; echo "inbox/<x...>/y/<z" >> soul/axes; msg=$(push "bad grammar" 2>&1)
yes  "bad grammar is refused too"    sh -c "echo '$msg' | grep -q 'bad pattern'"

echo "9. verify follows main only through signed commits"
fresh casey; sed -i '/^inbox\/<x/d; /^view tangle/d' soul/axes; push "repair axes" >/dev/null 2>&1
yes  "a fresh signed push verifies"   sh -c "cd '$W/kimi' && $SH ./project.sh verify origin"
mv "$R/hooks/pre-receive" "$R/hooks/off"
fresh kimi; echo x > PROTOCOL.md; git add -A; git -c commit.gpgsign=false commit -qm unsigned; git push -q origin HEAD:main
mv "$R/hooks/off" "$R/hooks/pre-receive"
same "the remote built views from the unsigned commit" "$(src by-task)" "$(rgit rev-parse main)"
not  "a body that verified main refuses them" sh -c "cd '$W/kimi' && $SH ./project.sh verify origin"
not  "so does a fresh clone, trusting only genesis" sh -c "git clone -q '$R' '$W/fresh' && cd '$W/fresh' && $SH ./project.sh verify origin"

echo; echo "$pass passed, $fail failed  (sh=$SH, awk=$AWK, $(rgit rev-list --count main) commits on main)"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi; [ "$fail" = 0 ]
