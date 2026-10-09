# git.pp architecture: the git-native agent, end to end

This document describes the whole system: how agents, judges, humans and machines share one
git repository as their only source of truth, and how the system keeps its own judgments honest.
It is written for whoever builds the next piece, human or agent. Each section says what exists
and is tested, what exists elsewhere in the fleet, and what is designed but not built.

The evidence behind the calibration and audit design is in
[`research/judges-that-never-grade-themselves.md`](research/judges-that-never-grade-themselves.md).

## The two laws

Everything below follows from two rules.

1. **Git is the system of record, and the push is the only act.** A thing has happened when a
   signed commit carrying it has been accepted by the remote. Anything outside git is either a
   cache rebuildable from the repo, a content-addressed blob the repo points to, or ephemeral
   and receipted by a commit.
2. **Nothing is graded on evidence it produced or selected.** An agent does not grade its own
   drafts, a judge does not certify its own confidence, a gate does not learn only from outcomes
   it chose to see, and a fleet does not check itself with copies of itself. Every grade comes
   from evidence that something else produced, chosen by a mechanism the graded party could not
   predict.

The first law makes the system durable and auditable. The second makes it honest. The research
found the second law broken, in some form, in every failure studied: self-correction without
outside signal made GPT-3.5 worse (75.8% to 38.1% on CommonsenseQA), evaluation on
self-selected outcomes "heavily underestimates failure rates", and two LLMs that are both wrong
pick the same wrong answer about 60% of the time.

## The shape

```
  hear: Telegram, files, sensors, people                 views: chat, TUI, dashboards
               │                                                   ▲
               ▼                                                   │ read only
  ┌──────────────────── refs/heads/main: acts ───────────────────┐ │
  │ inbox/  claimed/<body>/  done/<task>/   tasks and results    │ │
  │ bodies/<body>/          manifests, audit commitments         │─┼─ projector ─▶ refs/pp/*
  │ soul/                   signers, policy, axes, charter       │ │   (by-task, by-body,
  │ questions/  judges/     what is asked, who answers           │ │    by-hash, ...)
  └──────────────────────────────────────────────────────────────┘ │
  refs/heartbeat/<body>        liveness, overwritten, never history │
  refs/log/judgments/<body>    perception, append-only, one writer  │
               │                                                   │
               ▼                                                   │
     judgment cache (SQLite, rebuildable) ──▶ gates ──▶ act / hold / escalate
               │
               ▼
     window compiler ──▶ brief ──▶ agent ──▶ makes files ──▶ commit on main
```

Three kinds of state, three kinds of ref:

| Ref | Holds | Written by | Mutability |
|---|---|---|---|
| `refs/heads/main` | Acts: tasks, claims, results, manifests, policy | Every body, one writer per path | Append-only history, fast-forward only |
| `refs/heartbeat/<body>` | Liveness: a signed empty commit dated now | That body | Overwritten every tick |
| `refs/log/judgments/<body>` | Perception: every judgment the body made | That body | Add-only files, fast-forward only |
| `refs/pp/<view>` | Derived views of main | The remote's post-receive hook only | Rebuilt on every push, verifiable by recomputation |

Acts are low-volume and need history. Perception is high-volume and must stay out of main, or
every body's working tree and every projector run pays for it. Liveness has no history worth
keeping.

## Bodies

A body is a keypair, a manifest and a tick. The agent's identity is the repo, not any body.

| Body | Where | Role | Notes |
|---|---|---|---|
| Oracle | ARM, always on, CPU only | Spine: hosts the bare remote and its hooks, runs the projector, the judgment cache, the reaper and the audit selector | Needs no model for any of these roles |
| Laptop | WSL, RTX 4050 | Trains students, runs teachers, serves the interactive path | Sleeps; nothing may depend on it being awake |
| Kimi (prospector) | Cloud, 30-minute ticks | Consolidation, review, re-judging; candidate independent labeller | Least trusted; scoped key; measure its independence before using it as a labeller |
| Uno Q boards | Debian plus a real-time MCU, physical places | Sense and actuate | The MCU keeps the real-time loop and safe defaults; git carries observations and setpoints, never control signals |
| Casey | Anywhere | Owner: signs `soul/`, labels audits, sets acceptable error rates | Is also a judge in the log, with a track record like any other |

## Layer 1: the substrate

**Status: built and tested here.** `tick.sh` (85 lines of code), `pre-receive` (48), `test.sh`
(57 checks, passing under dash and bash).

The tick is a pure function: `tick(tree@main, capabilities) -> signed commits`. A body holds
nothing between ticks; after a kill anywhere, recovery is fetch and hard reset. The five rules,
and where each is enforced:

| Rule | Mechanism | Enforced by |
|---|---|---|
| Pure function | `sync` fetches, verifies every new commit, becomes exactly the tip | `tick.sh` |
| Push is the only act | `act` is the only writer: sync, one mutation, sign, push; a rejected push is discarded and re-decided, never merged | `tick.sh`; `pre-receive` refuses non-fast-forward pushes and merges |
| One writer per path | Six mutations, each moving or adding whole files in paths the body owns | `pre-receive` path rules |
| Intent before effect | `tick.sh effect KEY -- CMD`: the intent must land before CMD runs; a recorded result replays; an intent with no result refuses with exit 75 | `tick.sh`; the intent's commit hash is the idempotency key |
| Authority is a signature | Every commit is judged by its parent's `soul/allowed_signers` and `soul/policy` | `pre-receive` and every body's `sync` |

Claims are leased by heartbeat. A body that misses a lease is reaped; a sleeping laptop that
wakes mid-task finds its claim gone, and its effects are refused because an intent can only land
while the claim is held.

Known limits: an offline body is idle; one task per tick; task names must be unique forever; the
lease uses the body's own clock.

> The `tick.sh`, `pre-receive`, `test.sh` and `test-pp.sh` previously in this repo were
> reconstructed from a chat transcript rather than copied, and differed substantially from the
> tested draft. Their own test suite hung on its first section here: after each task the tick
> waits for the heartbeat loop's full `sleep` (300 s by default). With a 2-second heartbeat the
> suite ran and failed 27 of its 57 checks, starting with "result is in done/". Causes found on
> reading:
>
> - The executor wrote results into the working tree, and the next sync's `clean -fdx` wiped
>   them, including the `.tick/` scratch the done step then tried to copy.
> - Effect results were written but never committed, so replay could not work.
> - The reaper took the claim owner from the wrong path segment.
> - The signature check special-cased the principal `mallory`.
>
> This branch restores the tested versions.

## Layer 2: projection

**Status: built and tested here.** `soul/axes` (the coordinate grammar), `project.sh` (110
lines), `post-receive` (4), `test-pp.sh` (40 checks, passing under dash and bash with mawk, gawk
and busybox awk). `nexus.py` provides the reverse index as a Python tool.

A path such as `claimed/laptop/007` is a point with coordinates (state, body, task), flattened in
one axis order. `soul/axes` names the axes of each path family. A view is the same cells in a
different axis order: new tree objects pointing at the same blobs, so a view adds no blobs at
all. Views are declared as data, one line each, and the remote's post-receive hook rebuilds them
after every push to main.

A view commit is a pure function of the source commit: fixed author, the source's date, no
signature. Any body can recompute it with the projector stored in that same commit and compare
one hash; `project.sh verify` does this and refuses any source not on trusted main before
running its projector. The nexus (`by-hash`) maps every blob ever seen to every commit and path
where it appeared.

Measured cost: a rebuild after one push took 0.3 s at 1,500 commits, 0.9 s at 6,000 and 19 s at
60,000, and the pusher waits for it. It must become incremental before history reaches tens of
thousands of commits.

## Layer 3: perception

**Status: v0 live in `jev-semantic` (local TSV file, not yet in git). v2 schema, writer and
hook rule specified here; see the build order.**

### The judges

A judge is anything that turns (content, question) into a distribution over −1, 0, +1. The
6.8M-parameter intuition student is one; a big model, a human, a CI run and a sensor threshold
are others. Each judge has a manifest under `judges/` on main, and its identity is the blob hash
of that manifest:

```
name: intuition-student-v1
kind: student                 # student | teacher | llm | human | world | rollup
weights: <hash of the weights file>
encoder: <hash of the tokenizer or encoder>
teacher: <judge hash, or none>
data: <hash of the training-set manifest>
output: neg zero pos, four decimals
role: judge                   # judge | labeller | world
```

`teacher` and `data` are the lineage. They matter because independence has to be measured, not
assumed: a labeller from the same lineage as the judge is close to self-grading. A `world` judge
reports outcomes that no model produced, such as a test result, a human override, or a sensor
reading. World judgments sit at the top of the evidence hierarchy.

### The questions

A question is a file under `questions/` containing only the question text. Its identity is its
blob hash. Hierarchy is directory nesting. Moving a file re-parents a question without changing
its identity or its judgments. Rewording makes a new question; old judgments stay attached to the
old wording, and the path's history links the versions. `questions/root.md` is the one question
every student can condition on.

### The log

Each body appends to its own ref, `refs/log/judgments/<body>`, one new file per batch, never
modified. One line per judgment, tab-separated:

```
ts  subject  question  judge  neg  zero  pos  sel  prop  [key=value ...]
```

| Field | Meaning |
|---|---|
| `ts` | ISO-8601 UTC time of the judgment |
| `subject` | Git blob hash of the judged bytes, the same function the nexus uses |
| `question` | Blob hash of the question file |
| `judge` | Blob hash of the judge manifest |
| `neg zero pos` | The full probability vector, fixed order, four decimals |
| `sel` | Why this judgment exists: `stream`, `shadow`, `explore`, `audit`, `drill`, `appeal` or `flag` |
| `prop` | Probability that the selection mechanism routed this item here (1 for `stream`) |
| `key=value` | Optional; unknown keys are ignored. Reserved: `cfg=` gate-configuration hash, `seed=` audit-period id, `blind=1` (the judge saw no other verdict), `n=` evidence count |

The v0 lines already in the live log have seven fields; readers treat them as `sel=stream
prop=1`.

`sel` and `prop` are the most important fields in the system. Without them every downstream
estimate inherits the selection bias of whatever chose the items: the gate sees outcomes only for
what it acted on, and an audit that sampled hard items more often looks worse than the stream it
came from. With them, estimates can be reweighted by inverse propensity and stay unbiased. The
full probability vector is what makes proper scoring possible; an argmax cannot be scored.

The hook rule for log refs: fast-forward only, every commit signed by the body the ref names,
commits only add files, and every added line parses as v0 or v2.

### Reading the log

The log is the source of truth; the index is a rebuildable cache. On synthetic logs:

| Lines | Packed size | Scan for 200 subjects | SQLite cache build | Cache lookup, 200 subjects |
|---|---|---|---|---|
| 100k | 1.9 MB | 0.05 s | — | — |
| 1M | 19 MB | 0.5 s | 4.4 s, 127 MB | 5 ms |
| 10M | 185 MB | 7 s | 52 s, 1.3 GB | 8 ms |

Below about a million lines a full scan is fast enough. Above it, the cache answers both
directions (subject to judgments, question to judgments) in milliseconds and updates
incrementally. Putting one file per judgment on main instead would have cost a 4.9 GB working
tree on every body at 1M judgments.

### Determinism

The student's logits are bit-identical across x86_64 and aarch64. That has two consequences
pulling in opposite directions:

- **Auditing is cheap.** One label on a (subject, question, judge) key resolves that verdict for
  every copy of the judge, and an audit label recorded on one device is valid calibration data on
  every device.
- **The fleet is one fault domain.** A million copies are one opinion. They add throughput, not
  accuracy, and their errors are perfectly correlated.

It also makes "diff two minds" exact: re-judging all history with a new student and subtracting
gives the complete list of items it changed its mind about, with no noise.

## Layer 4: the window compiler

**Status: v0 built in `jev-semantic` (`window.py`). The full design is below.**

The compiler turns a task into a brief: the dense local context an agent needs, compiled
rather than searched. It is a pure function of pinned inputs, so a brief can be reproduced and
verified like a view.

1. **Pin** the main commit and every log tip. Read only from those.
2. **Seed** with the task blob, the blobs and hashes the task names, and the nexus hits. Each
   seed carries its reason.
3. **Zone:** one exact hop from the seeds: other parts of the same task, earlier blobs at the
   same paths, the same content elsewhere. Embedding neighbours, when added, are labelled
   approximate.
4. **Judgments:** the latest line per (subject, question, judge, body), each tagged settled,
   conflict, ignorance, disagreement or stale.
5. **Questions:** map hashes to paths, pull ancestors, count settled and open per question.
6. **Precedents:** done tasks linked to the zone, with outcomes. Bad outcomes rank first.
7. **Budget:** fixed space per section; overflow counted under "Not shown".
8. **Stamp:** write the pinned commits in the header, store the brief as
   `done/<task>/window.md`, and put a `Window:` trailer on the result commit. "What did the agent
   know when it acted?" is then one `git show`.

## Layer 5: gates

**Status: designed here; a reference implementation is in the build order.**

A gate decides, for each judgment, whether to act on it, hold, or escalate. The research
overturned two parts of the earlier design and formalized the rest.

### Act only when trust has been audited

For each region an item falls in, keep audited counts per (judge, question, region, verdict): how
many confident verdicts of that kind were checked, and how many were wrong. Act only if, in
**every** region containing the item, the Clopper–Pearson upper bound on the confident-error rate
is at or below the error rate the owner accepts for that action. A region with no audits has a
bound of 1, so the gate never acts there: untrusted until audited, with a stated confidence.

- **Regions overlap and must not come from the judge.** Use source, task family, question, and
  clusters from an embedding of different lineage. Clusters built from the judge's own features
  inherit its blind spots; the best automated slice finder recovered only 36% of planted error
  slices.
- **Cost.** With zero errors, 60 audited items bound the error rate below 4.9% at 95%
  confidence and 150 bound it below 2.0%. Calibration costs 60–150 labels per region, whatever
  the traffic.
- **Drift.** Each region's threshold moves online with its audit outcomes (adaptive conformal
  inference), with no retraining.
- **Neutral versus unknown.** The gate acts only when the verdict is a single label. A confident
  0 is a verdict, "nothing here". Spread mass is "I don't know". Folding both into the middle
  class conflates them.
- **Do not trust the distribution as a second-order signal.** Evidential outputs track their
  regularizer rather than real error rates. Plain softmax confidence is the baseline to beat;
  add a 5-seed ensemble and a density score only where audits show it ranks errors poorly.

### Price abstention, and route on comparative error

Abstaining is a purchase: it spends attention and gives up a label. The action rule is

```
cost(a | x) = expected error cost(a, x) + c_a − value of information(a, x)
```

for a in {act, hold, escalate to a big model, escalate to a human}. `c_human` is the shadow price
of the attention budget and rises as the queue fills. Value of information is the chance the
item's region recurs times the loss reduction a label would buy: novelty that will recur is worth
learning on, novelty that won't is worth asking about. The "abstention death spiral" is this rule
with value of information priced at zero.

Low confidence is the wrong reason to escalate. The optimal deferral rule compares the model's
expected error with the expert's expected error on that kind of item; escalating to a human who
is also bad in that region buys nothing. The gate therefore routes on the difference between
track records, which only blind audits that score the humans can supply.

Three mechanisms keep labels flowing into the regions the gate avoids:

- **Shadow judgments:** the student's verdict is logged on every escalated item (`sel=shadow`),
  so every escalation answer becomes a free label for the student.
- **Exploration on reversible actions:** a small, logged probability of acting anyway
  (`sel=explore`, `prop=ε`). Without some probability of acting in every region, the value of
  acting there cannot be estimated from the logs at all.
- **The audit stream** (next layer), which samples abstained and suppressed items too.

## Layer 6: independence

**Status: designed here; a reference implementation is in the build order.**

Independence is the scarce input. This layer mints it cheaply, spends it where information is
worth most, and records where it came from.

### The audit stream

An auditor body (the Oracle) selects items for audit with a secret seed committed in advance:

1. At the start of a period, commit `bodies/<auditor>/audit/<period>.commit` containing the
   SHA-256 of a fresh random seed and the sampling rate for each stratum.
2. During the period, select every judged (subject, question) whose keyed hash of the seed and
   key falls below its stratum's rate. Selection depends only on the content key, never on any
   verdict, so suppressed and abstained items are sampled at the same rate as acted ones.
3. Drop each selected item into `inbox/` as a blind task: the labeller sees the content and the
   question, not the verdicts.
4. At the end of the period, commit `bodies/<auditor>/audit/<period>.reveal` with the seed.
   Anyone can check it against the commitment and recompute the full selection from the log,
   which proves nothing selected was skipped and nothing was cherry-picked.

Judges cannot predict which of their verdicts will be audited, because the seed is secret until
the period closes. Strata may oversample hard or novel regions; each label carries its stratum
rate as `prop`, so estimates stay unbiased.

Labels are judgments: lines from labeller judges with `sel=audit blind=1`. They are never
edited, so they serve as a fixed anchor for every future judge version.

### Blind audits pay three times

A human labeller gives a probability before seeing any verdict, then sees the resolution and
their score. One unit of attention buys:

- **a forcing function** against over-reliance (deciding first measurably reduced it, N = 199);
- **calibration training** (under an hour of Brier feedback improved forecasters by 6–11%);
- **an unbiased label** for the judges.

Audit sets also carry **fault drills** (`sel=drill`): items where the student is known to be
wrong, shown with its verdict. They test directly whether reviewers still catch a faulty
instrument, the skill that decays first. In a simulator, 75% of experienced pilots followed a
faulty altimeter; experienced endoscopists' unassisted detection rate fell from 28.4% to 22.4%
within about three months of AI assistance.

### Track records

Every party is scored with a proper scoring rule (Brier) on the items that resolved: students,
big models, humans, and agents' own commitments. Scores are kept per (question, region).

- **Routing** uses the difference between track records, as above.
- **Deskilling alarm:** a reviewer's Brier score trending upward over time.
- **Escalation value:** the share of escalations where the target changed the outcome. Too low
  and the human channel is wasted; alarm studies report 72–99% false alarms, and people stop
  responding.
- **Capture signal:** agreement between an auditor and the judge it audits rising while accuracy
  stays flat.

### Correlated failure

- **Measure independence.** Before trusting a labeller, record how often it and the student are
  wrong together on a human-labelled anchor set, against chance. More accurate models make more
  correlated errors, and the student's own teacher is the least independent choice.
- **Polarization monitor.** Run three or more dissimilar judges on the audit stream and compare
  their observed all-wrong rate with what independence predicts. A rising ratio flags a new
  shared blind spot.
- **Bypass slice.** A small random share of items skips the student's suppression entirely and
  logs its propensity, so the world can be seen without the judge's filter.
- **Worst cluster, not the mean.** Report error per judge-independent cluster, worst first.
  Detecting a cluster rising from 5% to 10% error takes about 435 labels per cluster per
  window, so use sequential tests and pooling.
- **The audit rate is set by the smallest population you are willing to fail silently.**

### Shipping a new judge

A new student or rubric ships through a gate that reads the log:

- **Churn, not net change.** Re-judge the anchored set with the new judge and count, per
  cluster, items fixed and items newly broken. Block the release if any cluster breaks more than
  its threshold, even when the net change is positive. In a study of nine commercial ML services,
  one update fixed 78 shared failures and created 78 new ones.
- **Diff by cluster before any outcome.** Re-judge history and find the clusters whose verdicts
  moved most. "Who does the new model treat differently?" is answerable before release.
- **Drift decomposition.** Old judges are pure functions, so run the old judge on new content:
  the difference from its old verdicts is change in the world; the difference between old and
  new judges on the same content is change in the model.
- **Content is code.** Rubric, question and threshold changes get the same canary rollout as
  weights, and every decision records the gate-configuration hash (`cfg=`). CrowdStrike's 8.5
  million crashed machines came from a content file pushed everywhere at once; Knight Capital's
  $460 million loss from a deployment that reached only part of its servers.
- **Registry of consumers.** Every dashboard, ranker and training filter fed by a judge is
  listed, so a judge diff reaches everything that inherits it.

## Layer 7: the agent

**Status: designed here; the harness pieces are in the build order.**

An agent here is a model plus three harnesses: a way to hear, a way to remember, and a way to
make. It needs no code execution. The research supports three load-bearing constraints and adds
two:

| Constraint | What it means here | Evidence |
|---|---|---|
| Continuity | What it makes lands where it will read it again | All agent memory systems |
| Correction | What it hears includes the world's response to what it made, from outside | Removing checks against the world cut Voyager's discoveries by 73%; self-correction alone made models worse |
| Commitment | It can add to its past but not erase it | Models that accumulate real data alongside their own outputs avoid collapse; those that replace it collapse |
| Consolidation | A revisable summary above the immutable log | Generative Agents' raw memory alone scored below human crowdworkers (21.21 vs 22.95); the full system scored 29.89 |
| Norms | A charter file, re-read on every window, saying what the agent is for | Without a standard, correction has no direction |

What this means for the repo:

- **Two strata.** The raw log of what was heard and made is never rewritten. Consolidations are
  ordinary commits that revise summary files, made in idle time. Each window includes a verbatim
  slice of outside input as well as the summaries.
- **A charter** in the agent's directory, versioned like everything else.
- **Commitments as forecasts.** Each thing the agent makes registers the question that will
  resolve it, so the hearing channel closes the loop with an outcome and the agent enters the
  same scoring ledger as the judges.
- **The Jev as the agent's fast check.** A 7 ms judge gives a no-execution agent feedback faster
  than any human. It counts as outside correction only to the extent it is calibrated against
  the world and comes from a different lineage than the agent's model.
- **Identity is the memory.** Swap the model and keep the repo and you have the same agent with
  a different temperament. Capability does not carry over, so measure identity and competence
  separately whenever the model changes.

Without execution, the agent's correction loop runs at the speed of its readers. The design works
where people or other systems are the environment.

## Failure modes and escape hatches

| Failure | Defence |
|---|---|
| A body forges another's work | Signatures checked against the parent commit's signers, on the remote and on every body |
| A compromised remote | Bodies verify every commit themselves and halt on anything unsigned |
| A body acts after losing its claim | Intents can only land while the claim is held |
| Effect outcome unknown after a crash | Refused with exit 75, never retried blindly |
| Secrets or poisoned memory in history | Keep secrets out entirely; periodic signed epochs archive old history |
| A forged view | Recompute it with the source commit's own projector and compare hashes |
| Confident and wrong | Region gate on audited bounds; no audits means no action |
| Abstention starves calibration | Shadow judgments, exploration on reversible actions, audits of abstained items |
| Humans lose the skill | Blind audits as practice, fault drills, Brier trends |
| A million copies share a blind spot | Hash-selected audits including suppressed items, measured labeller independence, polarization monitor, worst-cluster reporting |
| A judge update breaks a population | Churn gate per cluster, canaries for content and configuration, `cfg=` on every decision |
| Dashboards drift with the model | Labels are append-only anchors; old judges re-run on new content |

## Build order and status

| # | Piece | Status | Done when |
|---|---|---|---|
| 1 | Substrate: tick, pre-receive | **Built, 57 checks** | — |
| 2 | Projection: axes, projector, post-receive | **Built, 40 checks** | — |
| 3 | Log v2: schema, writer to per-body refs, hook rule | Next | A backfill writes the live log to refs; a push that edits a line is rejected; v0 and v2 both parse |
| 4 | Audit stream: commit-reveal selector, blind tasks, fault drills | Next | A revealed seed reproduces the exact selection from the log, including suppressed items |
| 5 | Shadow judgments and exploration | Next | Every escalation produces a `sel=shadow` line; exploration logs `prop` |
| 6 | Region gate | Next | Unaudited regions never act; the bound matches the audit tables; thresholds move with outcomes |
| 7 | Track records and routing | Next | Every judge and reviewer has a Brier score per region; routing picks the lower expected loss |
| 8 | Ship gate | Next | A synthetic update that breaks one cluster is blocked despite a positive net change |
| 9 | Window compiler v1 | Partly built (`window.py`) | Briefs are byte-identical on a second body and stored with results |
| 10 | Agent harness v2: charter, consolidation, commitments as forecasts | Designed | An agent's commitments resolve into the scoring ledger |
| 11 | Ensembles and density scores | Deferred | Adopted only where audits show plain confidence ranks errors poorly |

## Experiments only this system can run cheaply

- How often the student and each candidate labeller are wrong together, per cluster.
- Student calibration before and after recalibrating its teacher (distilled students were more
  overconfident than their teachers in one study: 16.9 vs 9.3 calibration error).
- Mutable against append-only agent memory, A/B on the same tasks.
- The smallest exploration rate and audit floor that keep every region's bound moving.
- The full "diff two minds" between student versions over all history, per cluster.
