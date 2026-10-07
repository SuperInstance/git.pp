# The question loop

A process for projecting to the next level of questions, using the Jev
as the filter. For Muse's own use — working to the meta.

## The loop

1. **Generate.** Given the current state, write 5-10 candidate next
   questions. Aim past the obvious: what would change the build, what
   assumes something unexamined, what does the stranger not know to ask.

2. **Score.** Run each through the Jev (ternary):
   `jev.py noul "<context>. Next question candidate: <q>" "Is this the
   most load-bearing next question?" --true "answering this would
   change what we build" --false "this can wait or does not change
   the build"`

3. **Read the scores.**
   - Near 0 → trivia. Kill it.
   - Near 1 → the load-bearing question. Answer it next.
   - Clustered in the middle (0.4-0.6) → they're ALL real. Don't pick;
     sequence by dependency. The Jev can't rank genuine questions
     against each other — that's the orchestrator's job.

4. **Sequence.** For the survivors, ask: which unblocks which? The
   order is a DAG, not a ranking.

5. **Ask.** Pose the next question to the right mind (user, Opus,
   builder, skeptic). Record the answer as a commit — timestamped
   learning.

## What the scores mean

The Jev is a filter, not an oracle. It kills the logo-color questions
reliably (0.05). It cannot tell you which of three real questions
matters most — because they all do. The value is in the murk: a
cluster of 0.4-0.6 scores means you're asking at the right level and
the work is to sequence, not to choose.

## Tonight's run (2026-10-07)

- "Smallest physical fact worth committing?" → 0.43
- "How does a zero-shot body discover the ROM?" → 0.46
- "Principled resolution when projections disagree?" → 0.49
- "Parallel tick or one-task-per-tick?" → 0.47
- "What color should the logo be?" → 0.05

Four real questions, one trivia. The four survive together — sequence
by dependency, don't rank.
