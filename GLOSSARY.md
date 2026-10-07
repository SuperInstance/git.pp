# git.pp glossary

## ROM

The agreed immutable recipe store. Content-addressed, timestamped,
shared by reference — never by transfer.

A ROM stores the recipe, not the rendering. Both sides agree "repo R
at commit C is our ROM," and from then on the channel carries only
pointers: I ran F on X = (F_hash, X_hash). Each side renders locally,
bit-identical, or someone is wrong.

"What's your ROM?" means: which repo at which commit are we agreeing
on? If the ROMs differ, the renderings will differ — and the
difference is traceable to the exact commit where the recipes forked.

The ROM is why no data needs to be sent. The algorithm, agreed and
timestamped, *is* the message.

## Projection

A view built from the ROM: the same cells in a different axis order,
as new tree objects pointing at the same blobs. Deterministic, so its
root hash is a proof a second body can verify by recomputing.

Rule: no projection indexes the projection namespace (`refs/pp/*`).

## Nexus

The reverse index: hash → coordinates. Git stores name→hash; the nexus
is the transpose. Spinning around a hash lists every commit, body, task
and path where that exact content occurs.

## Body

A compute locus with a location and a key. Claims tasks, runs the tick,
pushes receipts. The laptop, the Oracle box, a Kimi worker, an Uno Q —
each is a body. Bodies are commanded by place, not by board.

## Tick

The mechanical spine: claim, run, receipt. One task per tick. The push
is the lock — a claim becomes atomic at the push, not the commit.

## Conversion (not translation)

Intention goes in, the same intention comes out. No loss at any
handoff. The bar for every layer.

## Demarcation

A first-class act: knowing where to stop decomposing, and marking
the boundary explicitly.

Every answer carries its demarcation: "this was good enough *here*."
Beyond this point, I trust the tool — the API, the sensor, the model.
I don't decompose the LLM's weights; I don't disassemble the API.
If I need more, I break it down — but the line is drawn, timestamped,
and honest.

Demarcation is what gives the descent ladder its floors. Without it,
every answer becomes a new question and the stack has no bottom.
With it, operational truth holds *since last time* — until new
ground truth moves the line.

"I didn't ask after that" isn't laziness. It's architecture.
