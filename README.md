# git.pp

Git, projected as an agent substrate.

Git is not GitHub. It is not a place. It is a content-addressable graph
database and a protocol for organisation — and that turns out to be
enough to run agents on.

`git.pp` projects git as the substrate agents live in, without
interrupting or replacing git. Trees, branches, and forges keep working
exactly as before. Underneath, the same objects become something else:
a fact table, a coordinate space, a ledger of intent and effect.

## The triad

Three things, decoupled so each evolves independently:

- **The agent that understands the user** — portable across
  applications and hardware. It carries the user, not the machine.
- **The hardware that understands itself agentically** — any
  application, any user, tailored on top. It carries the body, not
  the logic.
- **The logic layer of the application** — portable across hardware,
  for a different user. It carries the reasoning, not the room.

An agent that understands you can move between applications and
hardware. A board that understands itself can host any application for
any user. Logic written once runs on any body for anybody.

## Privacy is a topology

Decoupling is also the privacy architecture — and privacy is what lets
everything accelerate. When the application and the user data are one
bundle, whoever holds the app holds the data, and every step pays a
security tax. Separated, each layer moves at its own speed.

User data lives in the projection layer, which is computed where it is
viewed — which means it can stay local. The layers that understand the
user sit close to the user: private, efficient, low-latency. The
digestion — search, correlation, projection-building — sits where the
data centers are, next to the data.

- User + rendering compute → the edge, near the user.
- Digestion + search compute → the data center, near the data.
- Witness + actuation → the physical body, where the world is.

Git's distributed nature *is* the privacy architecture. Every clone is
local. A projection is a clone with views. Nothing about this requires
your data to leave the room to be useful.

## The test that never converges

The ultimate GAN is the user's test: did it meet *you*? There is no
definitive benchmark because every user is a new refinement, every
board a new body, every application a new shape. The discriminator
keeps moving — and that is the point. A closed GAN sharpens until
nothing is sharper; this one stays open, because the world keeps
dealing new cards.

## Agent-first

The future is agent-first, so this is built for the agents first. The
yoke moves to the hand: whoever grabs it — human, model, stranger —
finds the controls where they reached. A zero-shot agent clones the
repo and the repo teaches it what to do. The inbox is the interface,
the task file is the brief, "done when" is the contract.

And the loop is conversion, not translation: intention goes in, the
same intention comes out. No loss at any handoff — that is the bar.

## What's here

- `ARCHITECTURE.md` — the whole system, end to end: substrate, projection,
  perception, gates, independence, the agent, and the build order.
- `research/` — the evidence behind the calibration and audit design.
- `OPERATIONS.md` — standing the fleet up on real machines; every step is run by `test-ops.sh`.
- `tick.sh` — the mechanical spine: claim, run, receipt. One task per
  tick, push is the lock.
- `pre-receive` — the hook: one writer per path, intent before effect.
- `nexus.py` — the reverse index: hash → coordinates. Spin around any
  blob and see everywhere it occurs.
- `test.sh` — the substrate harness. 57 checks.
- `project.sh`, `post-receive`, `soul/axes` — derived views; `test-pp.sh`, 40 checks.
- `jlog.py`, `audit.py`, `gate.py`, `ledger.py`, `gatekeep.py`, `shipgate.py` — perception and
  calibration: judgment logs, the audit stream, the gate, track records, the ship gate.
- `window.py`, `forecast.py`, `consolidate.py`, `agent-exec.sh` — the agent: compiled windows,
  commitments as forecasts, a verifiable memory page, the reference executor.
- `ARCHITECTURE.md` — the whole system, end to end, with what is built and tested.
- `NOTES.md` — known caveats, honestly listed.

## Status

Playtesting. The gate out: the cold user stops bouncing, the nexus
holds on real history, the adversarial audit finds no unaddressed
fatals, the projector builds and verifies. Then it's the real thing.
