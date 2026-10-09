# Git-native agent tick spec — Opus 5.5 draft (2026-10-07)

Drafted by Opus 5.5 (claude.ai) against the agent-inbox layout, tested
with a 57-check harness against a scratch remote with three SSH-signed
bodies. All checks passed per the draft report.

## Files

- `tick.sh` — one tick of a git-native agent body (131 lines, POSIX sh).
- `pre-receive` — the remote's only law (48 lines). Install by hand in
  the bare repo's hooks/.
- `test.sh` — 57-check harness (throwaway remote + three bodies).

## The five rules as implemented

1. **Pure function:** `sync` fetches, verifies every new commit against
   the parent's signers, hard-resets to tip. Scratch goes to gitignored
   `.tick/`. After kill -9 anywhere: fetch && reset --hard recovers.
2. **Push is the only act:** `mutate()` is the sole writer — sync, apply
   one mutation, sign, push. Rejected push = lost the race = discard and
   re-decide next tick.
3. **One writer per path:** six mutations (publish, claim, requeue, reap,
   intend, record), each moving/adding whole files. No merges, ever.
4. **Intent before effect:** `tick.sh effect KEY -- CMD` — the intent
   commit must land on main before CMD runs; the intent hash is the
   idempotency key. Crash after effect → replay the recorded result,
   never re-run. Crash during → in-doubt, refused (exit 75).
5. **Signature authority:** every commit judged by the signers file and
   policy of its PARENT. No commit authorizes itself. Bodies may only
   touch their own claim/effect paths; only the owner touches soul/.

## New paths vs agent-inbox

- `soul/allowed_signers` + `soul/policy` (owner-signed genesis)
- `bodies/<id>/manifest` (caps: cpu gpu ...)
- `claimed/<id>/<task>.fx/` (effect ledger: KEY.intent, KEY.result)
- `refs/heartbeat/<id>` (signed empty commit, overwritten — not history)
- Tasks opt into matching with `needs: gpu` line.

## Honest limitations (from the draft)

- Offline body is idle — a claim needs a push. Stricter than hoped.
- One task per tick; no post-receive wake yet.
- Kimi scoping (partial repo) not built.
- Task names must be unique forever (use timestamp prefix).
- Clock trust: liveness uses the body's own clock; WSL-after-sleep skew
  can cause premature reaping.

## Verification caveats

- The earlier copies of `tick.sh`, `pre-receive`, `test.sh` and `test-pp.sh` here were
  transcribed from a chat file viewer and did not match the tested draft (their suite hung,
  then failed 27 of 57 checks with a short heartbeat). They have been replaced with the tested
  originals: `test.sh` passes 57 checks and `test-pp.sh` 40, under dash and bash.
- Nothing has run on our machines yet. The scratch remote was throwaway.

## Chat

https://claude.ai/chat/a86cc57e-337a-4b10-9e99-ab36d7980c8f

## Next decision

Adopting this replaces the current inbox claim/done flow the claw and
Prospector are using. Options: (a) test on a scratch repo first,
(b) migrate agent-inbox to the tick protocol, (c) adopt pieces
incrementally (signatures, intent-before-effect). Awaiting Casey's call.
