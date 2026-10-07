#!/bin/bash
# test.sh -- builds a throwaway remote + three bodies and exercises tick.sh and pre-receive.
#   ./test.sh            (SH=dash ./test.sh or SH=bash ./test.sh to pick the shell tick.sh runs under)
# NOTE: transcribed from Opus 5.5's draft -- verify against the claude.ai chat attachments
# before treating as authoritative. See NOTES.md.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); W=$(mktemp -d); export WORLD="$W/world"
SH=${SH:-sh}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null # ignore the host's own git/signing setup
mkdir -p "$WORLD" "$W/keys" "$W/bin"; pass=0; fail=0
ok() { pass=$((pass+1)); echo "  ok $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }
yes() { n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
not() { n=$1; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }
R="$W/remote.git"
rgit() { git -C "$R" "$@"; }
has() { rgit cat-file -e "main:$1"; }
count() { rgit rev-list --count main; }
who() { rgit -c gpg.ssh.allowedSignersFile="$W/signers" log -1 --format=%GS main -- "$1"; }

# --- keys, genesis, remote, hook --------------------------------------------------------------
for k in casey oracle laptop kimi; do ssh-keygen -q -t ed25519 -N '' -C "$k" -f "$W/keys/$k"; done
clone() { # clone <dir> <principal>
    git clone -q "$R" "$W/$1" 2>/dev/null || git init -q -b main "$W/$1"
    git -C "$W/$1" config gpg.format ssh
    git -C "$W/$1" config user.signingkey "$W/keys/$2"
    git -C "$W/$1" config user.name "$2"
    git -C "$W/$1" config user.email "$2@agent"
}
git init -q --bare -b main "$R"
clone seed casey; cd "$W/seed"; git remote add origin "$R" 2>/dev/null
mkdir soul
for k in casey oracle laptop kimi; do echo "$k $(cut -d' ' -f1,2 "$W/keys/$k.pub")"; done > soul/allowed_signers
printf 'owner: casey\nlease: 3\n' > soul/policy
cp soul/allowed_signers "$W/signers"
cp "$HERE/tick.sh" .
echo "# protocol" > PROTOCOL.md
git add -A; git commit -qS -m genesis; git push -q origin main
cp "$HERE/pre-receive" "$R/hooks/pre-receive"; chmod +x "$R/hooks/pre-receive"
for b in oracle laptop kimi; do clone "$b" "$b"; clone "x-$b" "$b"; done
clone x-mallory mallory; clone x-casey casey

# --- helpers ----------------------------------------------------------------------------------
tick() { b=$1; shift; ( cd "$W/$b" && env AGENT_ID="$b" "$@" "$SH" ./tick.sh ); } # tick <body> VAR=val...
task() { ( cd "$W/x-casey" && git pull -q && mkdir -p inbox && printf '%s\n' "$2" > "inbox/$1" && git add -A && git commit -qS -m "task $1" && git push -q origin main ); }
fresh() { cd "$W/x-$1" && git fetch -q origin && git checkout -qfB main origin/main && git clean -qfdx; }
push() { git add -A && git commit -qS -m "${1:-x}" && git push -q origin HEAD:main; }
exe() { printf '#!/bin/sh\n%s\n' "$2" > "$W/bin/$1"; chmod +x "$W/bin/$1"; }
exe echo 'echo "hello from $AGENT_ID" > "$2/answer"'
exe effect '$SH "$TICK" effect notify -- sh -c '\''echo "$INTENT" >> "$WORLD/log"; echo sent'\'' > "$2/reply" || exit $?; [ -e "$WORLD/crashed" ] || { touch "$WORLD/crashed"; kill -9 $PPID; }'
exe doubt '$SH "$TICK" effect pay -- sh -c '\''echo paid >> "$WORLD/pay"; kill -9 $PPID'\''; rc=$?; [ -e "$WORLD/died" ] || { touch "$WORLD/died"; kill -9 $PPID; }; exit $rc'
exe sleepy 'sleep 7; $SH "$TICK" effect late -- sh -c '\''echo x >> "$WORLD/late"'\''; echo $? > "$WORLD/zombie_rc"'

echo "1. basic flow"
task 001-hello "say hello"; tick oracle CAPS=cpu EXEC="$W/bin/echo"
yes "result is in done/" has done/001-hello/answer
yes "task file travelled with it" has done/001-hello/task
not "inbox is empty" has inbox/001-hello
not "claim is released" has claimed/oracle/001-hello
yes "signed by oracle" [ "$(who done/001-hello/answer)" = oracle ]
yes "trailers present" sh -c "git -C '$R' log -1 --format=%B main | grep -q '^Body: oracle' && git -C '$R' log -1 --format=%B main | grep -q '^Soul: '"
yes "manifest published" has bodies/oracle/manifest
n=$(count); tick oracle CAPS=cpu EXEC="$W/bin/echo"
yes "idle tick leaves no commit" [ "$(count)" = "$n" ]
yes "heartbeat ref exists" rgit rev-parse -q --verify refs/heartbeat/oracle

echo "2. capability matching"
task 002-gpu "$(printf 'needs: gpu\nrender')"; tick oracle CAPS=cpu EXEC="$W/bin/echo"
yes "cpu body leaves gpu task" has inbox/002-gpu
tick laptop CAPS="cpu gpu" EXEC="$W/bin/echo"
yes "gpu body does it" [ "$(who done/002-gpu/answer)" = laptop ]

echo "3. claim race (oracle pushes between laptop's commit and laptop's push)"
task 003-a "a"; task 003-b "b"
cat > "$W/laptop/.git/hooks/pre-push" <<EOF
#!/bin/sh
rm -f "$0"; cd "$W/oracle" && env -u GIT_DIR -u GIT_INDEX_FILE AGENT_ID=oracle CAPS=cpu EXEC="$W/bin/echo" $SH ./tick.sh
EOF
chmod +x "$W/laptop/.git/hooks/pre-push"
tick laptop CAPS="cpu gpu" EXEC="$W/bin/echo"
yes "winner did the contested task" [ "$(who done/003-a/answer)" = oracle ]
yes "loser re-decided, took next" [ "$(who done/003-b/answer)" = laptop ]
yes "exactly one claim of 003-a" [ "$(rgit log --format=%s main | grep -c '^claim 003-a$')" = 1 ]

echo "4. hook: what a body cannot do"
task 004-keep "keep"; H=$(rgit rev-parse main)
fresh mallory; echo x > inbox/evil; git add -A; git -c commit.gpgsign=false commit -qm unsigned
not "unsigned commit" git push -q origin HEAD:main
fresh mallory; echo x > inbox/evil
not "unknown key" push
fresh mallory; echo "mallory $(cut -d' ' -f1,2 "$W/keys/mallory.pub")" >> soul/allowed_signers
not "self-introduction" push
fresh mallory; echo "mallory $(cut -d' ' -f1,2 "$W/keys/mallory.pub")" >> soul/allowed_signers; echo "owner: mallory" >> soul/policy
not "self-coronation" push
fresh kimi; echo "owner: kimi" >> soul/policy
not "body edits soul/" push
fresh kimi; echo x >> PROTOCOL.md
not "body edits PROTOCOL.md" push
fresh kimi; mkdir -p claimed/laptop; echo x > claimed/laptop/planted
not "body writes another's claim" push
fresh kimi; mkdir -p done/zzz; echo x > done/zzz/answer
not "result without a claim" push
fresh kimi; echo x >> done/001-hello/answer
not "rewriting a finished result" push
fresh kimi; git rm -q inbox/004-keep
not "deleting a task unclaimed" push
fresh kimi; echo x > "inbox/bad name"
not "unsafe path" push
fresh kimi; git commit -qS --allow-empty --amend -m rewritten
not "force push" git push -qf origin HEAD:main
fresh kimi; git checkout -q -b side HEAD~1; mkdir -p inbox; echo s > inbox/side; git add -A; git commit -qS -m side
git checkout -q main; git merge -q -S --no-ff side -m merge
not "merge commit" git push -q origin HEAD:main
fresh kimi
not "any other branch" git push -q origin HEAD:refs/heads/feature
not "deleting main" git push -q origin :refs/heads/main
not "someone else's heartbeat" git push -qf origin HEAD:refs/heartbeat/laptop
yes "main untouched by all of it" [ "$(rgit rev-parse main)" = "$H" ]
fresh kimi; echo "subtask" > inbox/004-sub
yes "body may add a task" push
fresh casey; echo "# reviewed" >> soul/policy
yes "owner may edit soul/" push
tick oracle CAPS=cpu EXEC="$W/bin/echo"; tick oracle CAPS=cpu EXEC="$W/bin/echo" # drain 004-*
not "inbox drained" has inbox

echo "5. effects: intent before effect, replay after crash"
task 005-fx "notify"; tick oracle CAPS=cpu EXEC="$W/bin/effect" 2>/dev/null
yes "tick was killed mid-task" has claimed/oracle/005-fx
yes "effect ran once" [ "$(wc -l < "$WORLD/log")" = 1 ]
yes "INTENT is the intent commit" [ "$(rgit log --format=%H --grep='^intent 005-fx/notify' main)" = "$(cat "$WORLD/log")" ]
tick oracle CAPS=cpu EXEC="$W/bin/effect"
yes "resumed and finished" has done/005-fx/reply
yes "effect NOT re-run on resume" [ "$(wc -l < "$WORLD/log")" = 1 ]
yes "replayed output reached exec" [ "$(rgit show main:done/005-fx/reply)" = sent ]
yes "ledger filed with result" has done/005-fx/fx/notify.result
yes "order: claim,intent,result,done" [ "$(rgit log --reverse --format=%s main | grep 005-fx | cut -d' ' -f1 | tr '\n' ' ')" = "task claim intent result done " ]

echo "6. effects: crash between effect and result = in doubt, never re-run"
task 006-pay "pay"; tick laptop CAPS=cpu EXEC="$W/bin/doubt" 2>/dev/null
yes "intent recorded, no result" sh -c "git -C '$R' cat-file -e main:claimed/laptop/006-pay.fx/pay.intent && ! git -C '$R' cat-file -e main:claimed/laptop/006-pay.fx/pay.result"

echo "7. reap: the in-doubt task's body never comes back"
tick oracle CAPS=cpu REAP=1
yes "not reaped while lease is live" has claimed/laptop/006-pay
fresh oracle; mkdir -p inbox; git mv claimed/laptop/* inbox/
not "hook refuses an early reap" push
sleep 4; tick oracle CAPS=cpu REAP=1
yes "reaped after lease expires" has inbox/006-pay
yes "effect ledger went with it" has inbox/006-pay.fx/pay.intent
tick kimi CAPS=cpu EXEC="$W/bin/doubt"
yes "next body refuses the effect" [ "$(rgit show main:done/006-pay/status)" = 75 ]
yes "the world was touched once" [ "$(wc -l < "$WORLD/pay")" = 1 ]

echo "8. zombie: laptop sleeps mid-task, is reaped, wakes up"
task 008-nap "$(printf 'needs: gpu\nnap')"
tick laptop CAPS="cpu gpu" EXEC="$W/bin/sleepy" BEAT=100 & z=$!
sleep 5; tick oracle CAPS=cpu REAP=1
yes "reaped while asleep" has inbox/008-nap
wait $z
yes "zombie's effect was refused" [ "$(cat "$WORLD/zombie_rc")" = 75 ]
not "zombie never touched the world" test -e "$WORLD/late"
not "zombie's result was discarded" has done/008-nap
tick laptop CAPS="cpu gpu" EXEC="$W/bin/echo"
yes "awake again, it redoes the task" [ "$(who done/008-nap/answer)" = laptop ]

echo "9. a body does not trust the remote either"
mv "$R/hooks/pre-receive" "$R/hooks/off"; fresh mallory; mkdir -p inbox; echo x > inbox/evil; push >/dev/null 2>&1
mv "$R/hooks/off" "$R/hooks/pre-receive"; H=$(git -C "$W/kimi" rev-parse refs/verified/main)
not "tick halts on untrusted history" tick kimi CAPS=cpu EXEC="$W/bin/effect"
yes "and does not advance" [ "$(git -C "$W/kimi" rev-parse refs/verified/main)" = "$H" ]
not "and does not run the task" has done/evil

echo; echo "$pass passed, $fail failed  (sh=$SH, $(count) commits on main)"
if [ -n "${KEEP:-}" ]; then echo "kept: $W"; else rm -rf "$W"; fi
[ "$fail" = 0 ]
