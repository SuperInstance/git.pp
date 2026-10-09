#!/bin/sh
# tick.sh -- one tick of one body:  tick(tree@main, capabilities) -> signed, pushed commits
#
#   tick.sh                        run one tick (cron, timer, or a post-receive wake)
#   tick.sh effect KEY -- CMD...   called by the executor for anything that touches the world
#
# env  AGENT_ID  this body's principal in soul/allowed_signers, and its directory name
#      CAPS      what this body can do, e.g. "cpu net gpu"; matched against a task's "needs:" line
#      EXEC      the body's cognition: EXEC <task-file> <out-dir>. Whatever it leaves in out-dir
#                becomes done/<task>/ (names task, fx, log, status are reserved). Unset = no work.
#      REAP=1    also requeue claims whose body has not heartbeaten within soul/policy "lease:"
#      BEAT      seconds between heartbeats while EXEC runs (default 300)
#
# The clone is this body's alone and holds nothing: every sync does a hard reset and clean -x.
# It must be able to sign:  git config gpg.format ssh; git config user.signingkey <path-to-key>
set -u
ID=${AGENT_ID:?} CAPS=${CAPS:-} BEAT=${BEAT:-300} TASK=${TASK:-}
cd "${REPO:-$(dirname "$0")}" && G=$(git rev-parse --absolute-git-dir) || exit 1
export GIT_AUTHOR_NAME="$ID" GIT_AUTHOR_EMAIL="$ID@agent" GIT_COMMITTER_NAME="$ID" GIT_COMMITTER_EMAIL="$ID@agent"

die() { echo "tick[$ID]: $*" >&2; exit 1; }

# RULE 5 -- authority is a signature. A commit is trusted only if a key listed in its PARENT's
# soul/allowed_signers signed it, so nobody can introduce themselves.
trusted() { git show "$1^:soul/allowed_signers" >"$G/tick.signers" 2>/dev/null &&
            git -c gpg.ssh.allowedSignersFile="$G/tick.signers" verify-commit "$1" 2>/dev/null; }

# RULE 1 -- the tick is a pure function of the tip. Fetch, verify everything since the last
# verified tip, then become exactly that tree. refs/verified/main is local; the first run pins it.
sync() {
  git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' '+refs/heartbeat/*:refs/heartbeat/*' || return 1
  new=$(git rev-parse origin/main); old=$(git rev-parse -q --verify refs/verified/main || echo "$new")
  git merge-base --is-ancestor "$old" "$new" || die "main was rewritten; re-pin refs/verified/main by hand"
  for c in $(git rev-list "$old..$new"); do trusted "$c" || die "untrusted commit $c on main"; done
  git update-ref refs/verified/main "$new"
  git checkout -qfB main "$new" && git clean -qfdx
}

# RULE 2 -- the push is the only act. Every state change in the system is this function:
# start from the fresh tip, apply one mutation, sign, push. A rejected push means we lost a race,
# so we do not merge or rebase: we throw the commit away and re-decide from the new tip.
# A mutation returning non-zero means "no longer applicable", and nothing happens.
act() {
  msg=$1; shift
  for _ in 1 2 3 4 5; do
    sync || return 1
    "$@" && git add -A && git commit -qS -m "$msg" --trailer "Body: $ID" --trailer "Task: ${TASK:--}" \
      --trailer "Model: ${MODEL:--}" --trailer "Soul: $(git rev-parse HEAD:soul)" || return 1
    git push -q origin HEAD:main 2>/dev/null && return 0
  done
  return 1
}

# RULE 3 -- one writer per path. These are all the mutations there are. Each only moves or adds
# whole files inside paths this body owns, so two commits can race but never conflict.
publish() { mkdir -p "bodies/$ID" && echo "caps: $CAPS" >"bodies/$ID/manifest"; }
claim()   { [ -f "inbox/$1" ] && [ ! -e "done/$1" ] && mkdir -p "claimed/$ID" &&
            git mv "inbox/$1" "claimed/$ID/$1" &&
            { [ ! -d "inbox/$1.fx" ] || git mv "inbox/$1.fx" "claimed/$ID/$1.fx"; }; }
finish()  { [ -f "claimed/$ID/$TASK" ] && mkdir -p "done/$TASK" && cp -R "$1/." "done/$TASK/" &&
            git mv "claimed/$ID/$TASK" "done/$TASK/task" &&
            { [ ! -d "$FX" ] || git mv "$FX" "done/$TASK/fx"; }; }
requeue() { [ -d "claimed/$1" ] && mkdir -p inbox && git mv "claimed/$1"/* inbox/; }
intend()  { [ -f "claimed/$ID/$TASK" ] && mkdir -p "$FX" && echo "$2" >"$FX/$1.intent"; }
record()  { [ -f "$FX/$1.intent" ] && cp "$2" "$FX/$1.result"; }

# Liveness is a ref that gets overwritten, not history: a signed empty commit, dated now.
beat() { git push -qf origin "$(git commit-tree -S -m beat "$(git mktree </dev/null)"):refs/heartbeat/$ID" 2>/dev/null; }

# RULE 4 -- intent before effect. The intent must land on main before CMD runs, and landing
# requires still holding the claim, so a body that was reaped while asleep cannot act on the world.
# A recorded result is replayed, never re-run. An intent with no result means a crash in between:
# the outcome is unknown, so we refuse (exit 75) and leave it to a human or a follow-up task.
# CMD gets INTENT=<commit hash> to pass downstream as an idempotency key.
effect() {
  key=$1; shift 2; : "${TASK:?effect must be called from inside a task}"
  sync || return 75
  [ ! -f "$FX/$key.result" ] || { sed 1d "$FX/$key.result"; return "$(sed -n '1s/^rc=//p' "$FX/$key.result")"; }
  [ ! -f "$FX/$key.intent" ] || { echo "effect $key: intended before, outcome unknown" >&2; return 75; }
  act "intent $TASK/$key" intend "$key" "$*" || return 75
  tmp=$(mktemp); echo "rc=?" >"$tmp"
  INTENT=$(git rev-parse HEAD) "$@" >>"$tmp" 2>&1; rc=$?
  sed -i "1s/.*/rc=$rc/" "$tmp"; sed 1d "$tmp"
  act "result $TASK/$key rc=$rc" record "$key" "$tmp"; rm -f "$tmp"; return "$rc"
}

eligible() { for n in $(sed -n 's/^needs: *//p' "$1"); do
               case " $CAPS " in *" $n "*) ;; *) return 1 ;; esac; done; }

# Any body may reap; the remote's hook is the judge of whether a claim is really dead.
reap() {
  now=$(date +%s); lease=$(sed -n 's/^lease: *//p' soul/policy)
  for d in claimed/*/; do
    w=$(basename "$d"); [ -d "$d" ] && [ "$w" != "$ID" ] || continue
    seen=$(git log -1 --format=%ct "refs/heartbeat/$w" -- 2>/dev/null)
    [ $((now - ${seen:-0})) -le "${lease:?soul/policy has no lease}" ] || act "reap $w" requeue "$w"
  done
}

tick() {
  sync || exit 0                                    # offline: nothing can happen, so nothing does
  beat
  [ "$(cat "bodies/$ID/manifest" 2>/dev/null)" = "caps: $CAPS" ] || act "manifest $ID" publish
  [ -z "${REAP:-}" ] || reap
  [ -n "${EXEC:-}" ] || exit 0

  TASK=$(ls "claimed/$ID" 2>/dev/null | grep -v '\.fx$' | head -n1)   # an unfinished claim comes first
  [ -n "$TASK" ] || for f in inbox/*; do
    [ -f "$f" ] && eligible "$f" || continue
    TASK=${f#inbox/}; act "claim $TASK" claim "$TASK" && break; TASK=
  done
  [ -n "$TASK" ] || exit 0                          # idle ticks leave no commit, only the heartbeat

  FX="claimed/$ID/$TASK.fx"; out=$(mktemp -d)
  export TASK AGENT_ID="$ID" REPO="$PWD" TICK="$PWD/tick.sh"
  ( exec 9>&- >/dev/null 2>&1; while sleep "$BEAT" && kill -0 $$ 2>/dev/null; do beat; done ) & hb=$!
  "$EXEC" "claimed/$ID/$TASK" "$out" >"$out/log" 2>&1; echo $? >"$out/status"
  kill "$hb" 2>/dev/null
  act "done $TASK" finish "$out"; rm -rf "$out"     # failure is a result too: it lands in done/ with its status
}

main() {
  FX="claimed/$ID/$TASK.fx"
  case ${1:-tick} in
    effect) shift; effect "$@" ;;
    tick)   exec 9>"$G/tick.lock"; flock -n 9 || exit 0; tick ;;   # one tick per body at a time
    *)      die "usage: tick.sh [effect KEY -- CMD...]" ;;
  esac
}
main "$@"; exit $?   # keep on one line: the file is replaced under us by sync, so it must be fully read by now
