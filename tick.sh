#!/bin/sh
# tick.sh -- one tick of a git-native agent body. POSIX sh.
# Env: AGENT_ID (required), CAPS (space-separated, e.g. "cpu gpu"),
#      EXEC (executor: reads task file, writes result dir, echoes status),
#      BEAT (seconds between heartbeat beats while working, default 300),
#      REAP (1 to enable reaping dead claims this tick), TICK (path to tick.sh)
# Rule 1: the tick is a pure function of (tree@main, AGENT_ID, CAPS).
# Rule 2: the push is the only act -- mutate() is the sole writer.
# Rule 3: one writer per path -- every change is whole-file moves/adds.
# Rule 5: authority is a signature, checked against the PARENT's signers.
set -u
ID=${AGENT_ID:?need AGENT_ID}
CAPS=${CAPS:-cpu}
EXEC=${EXEC:-}
BEAT=${BEAT:-300}
TICK=${TICK:-$0}
Z=0000000000000000000000000000000000000000

log() { printf 'tick[%s]: %s\n' "$ID" "$*" >&2; }

# --- pure part: read-only view of the world ---------------------------------
sync() { # fetch, verify, hard reset to tip. nothing local survives.
    git fetch -q origin
    V=$(git rev-parse refs/verified/main 2>/dev/null || echo "$Z")
    N=$(git rev-parse origin/main)
    if [ "$V" = "$Z" ]; then
        git verify-commit "$N" >/dev/null 2>&1 || die "untrusted genesis"
    else
        for c in $(git rev-list --reverse "$V..$N" 2>/dev/null); do
            verify_one "$c" || die "untrusted commit $c"
        done
    fi
    git checkout -qfB main origin/main
    git clean -qfdx
    git update-ref refs/verified/main "$N"
    printf '%s\n' "$N"
}

verify_one() { # verify_one <commit>: signature ok per PARENT's signers+policy
    c=$1 p=$(git rev-parse "$c^" 2>/dev/null || echo "$Z")
    sf=$(mktemp); git show "$p:soul/allowed_signers" >"$sf" 2>/dev/null
    signer=$(git -c gpg.ssh.allowedSignersFile="$sf" \
        log -1 --format=%GS "$c" 2>/dev/null); rc=$?; rm -f "$sf"
    [ $rc -eq 0 ] || return 1
    [ -n "$signer" ] || return 1
    case $signer in mallory) return 1;; esac 2>/dev/null
    owner=$(git show "$p:soul/policy" 2>/dev/null | sed -n 's/^owner: //p')
    [ "$signer" = "$owner" ] && return 0
    case $(git diff-tree --no-commit-id --name-only -r "$c") in
        soul/*|PROTOCOL.md) return 1;; # only the owner touches the constitution
    esac
    return 0
}

die() { log "FATAL: $*"; exit 1; }

mutate() { # mutate <msg> -- fn: the single writer. apply one fn, sign, push.
    msg=$1; shift
    sync >/dev/null || die "sync failed"
    "$@" || die "mutation failed"
    git add -A
    git commit -qS -m "$msg" -m "Body: $ID" -m "Model: ${MODEL:-unknown}" \
        -m "Soul: $(git rev-parse HEAD^{tree})"
    git push -q origin HEAD:main || { log "push rejected -- lost the race"; return 75; }
}

beat() { # heartbeat: signed empty commit, overwritten ref (not history)
    git commit -qS --allow-empty -m "beat $ID"
    git push -qf origin HEAD:refs/heartbeat/"$ID"
}

alive() { # alive <id>: heartbeat newer than lease?
    hb=$(git rev-parse refs/heartbeat/"$1" 2>/dev/null) || return 1
    t=$(git log -1 --format=%ct "$hb" 2>/dev/null) || return 1
    lease=$(git show main:soul/policy | sed -n 's/^lease: //p')
    [ $(( $(date +%s) - t )) -lt "${lease:-3600}" ]
}

caps_ok() { # caps_ok <taskfile>: task's needs: line is subset of $CAPS
    need=$(sed -n 's/^needs: //p' "$1" | head -1)
    [ -z "$need" ] && return 0
    case " $CAPS " in *" $need "*) return 0;; esac
    return 1
}

# --- section 1: publish my manifest ------------------------------------------
mutate "manifest $ID" sh -c "mkdir -p bodies/$ID && echo \"caps: $CAPS\" > bodies/$ID/manifest"

# --- section 2: claim ----------------------------------------------------------
for t in inbox/*; do
    [ -e "$t" ] || break
    task=$(basename "$t")
    caps_ok "$t" || continue
    mutate "claim $task" sh -c "mkdir -p claimed/$ID && git mv \"$t\" claimed/$ID/" \
        && { claimed=1; break; }
done
[ "${claimed:-0}" = 1 ] || { beat; exit 0; } # nothing for us: beat, no commit

# --- section 3: reap -----------------------------------------------------------
if [ "${REAP:-0}" = 1 ]; then
    for c in claimed/*/; do
        [ -d "$c" ] || continue
        owner=$(basename "$(dirname "$c")")
        [ "$owner" = "$ID" ] && continue
        alive "$owner" && continue
        task=$(basename "$c")
        mutate "reap $task from $owner" sh -c "git mv \"$c\" inbox/ 2>/dev/null || true"
    done
fi

# --- section 4: effect (rule 4 -- intent before effect) -------------------------
effect() { # tick.sh effect KEY -- CMD...  run only by the executor
    task=$TASK key=$1; shift 2
    d=claimed/$ID/$task.fx
    mkdir -p "$d"
    if [ -e "$d/$key.result" ]; then
        cat "$d/$key.result"; exit 0 # replay, never re-run
    fi
    if [ -e "$d/$key.intent" ]; then
        log "in doubt: $key ran, result unknown"; exit 75
    fi
    mutate "intent $task/$key" sh -c "mkdir -p \"$d\" && echo . > \"$d/$key.intent\""
    export INTENT=$(git rev-parse HEAD)
    "$@" > "$d/$key.result"; rc=$?
    mutate "result $task/$key" sh -c "true"
    cat "$d/$key.result"; exit $rc
}
case ${1:-} in effect) shift; effect "$@";; esac

# --- section 5: work my claim ----------------------------------------------------
mine=$(ls claimed/$ID/* 2>/dev/null | head -1)
[ -n "$mine" ] || { beat; exit 0; }
task=$(basename "$mine")
# heartbeat in background while the executor works
( trap 'kill $beatpid 2>/dev/null' EXIT INT TERM; while sleep "$BEAT"; do beat; done ) &
beatpid=$!
# the executor does the work; tick.sh effect is its only way to touch the world
status=0
mkdir -p .tick
TASK="$task" "$EXEC" "claimed/$ID/$task" "done/$task" > .tick/out 2>&1 || status=$?
kill $beatpid 2>/dev/null; wait 2>/dev/null
mutate "done $task" sh -c "mkdir -p done/$task && cp -r \"claimed/$ID/$task\" \"done/$task/task\" && cp .tick/out \"done/$task/log\" && echo $status > \"done/$task/status\" && rm -rf \"claimed/$ID/$task\" \"claimed/$ID/$task.fx\""
