#!/usr/bin/env python3
"""consolidate.py -- a body's memory: its own history, compiled into one page it reads first.

  consolidate.py digest  --body B [--at COMMIT --tips BODY=COMMIT,...] [--budget N]
      Print the memory page for body B, compiled from main at COMMIT and the judgment logs at
      their tips (default: the remote's current ones).
  consolidate.py publish --body B [--budget N]
      Compile against the current pins and publish it as bodies/B/memory.md, unless nothing
      but the pins changed.
  consolidate.py verify  --body B [--at COMMIT]
      Recompute bodies/B/memory.md (on main, or at COMMIT) from the pins in its own header and
      compare byte for byte.

The page is a pure function of its pins, like a view or a window: it says only what the record
shows, and anyone can check it. Sections:
  Record      tasks this body finished, failures first, each failure with its last log line
  Forecasts   what it predicted about its own work and how the world resolved it, with its
              Brier score: the one number about an agent that the agent did not produce
  Gate        what happened to the judgments it logged: acted on, explored, escalated, bypassed
  Corrections its verdicts that a person or the world resolved the other way
A model-written reflection, if a fleet wants one, is a task whose window includes this page;
its output is an ordinary result, judged like any other. Standard library only.
"""
import os, re, sys
from collections import Counter
import audit, jlog, ledger
from ledger import argmax
from window import tree_blobs

HEADER = re.compile(r"^main@([0-9a-f]{40})((?: [A-Za-z0-9._-]+@[0-9a-f]{40})*)$", re.M)


def who_claimed(repo, at):
    """{task: body} from every claim on main's history: the tick adds claimed/<body>/<task>."""
    out = {}
    raw = jlog.git(repo, "log", "--no-renames", "--diff-filter=A", "--name-only", "--format=", at, "--", "claimed/")
    for path in raw.splitlines():
        m = re.match(r"claimed/([^/]+)/([^/]+)$", path)
        if m and not m.group(2).endswith(".fx"):
            out.setdefault(m.group(2), m.group(1))       # newest first: the body that finished it
    return out


def digest(repo, body, at, tips, budget=12):
    files = tree_blobs(repo, at)
    cat = lambda path: jlog.git(repo, "cat-file", "-p", files[path]) if path in files else ""
    lines = list(jlog.iter_log(repo, tips=tips))
    mans = {}
    for path, blob in files.items():
        if path.startswith("judges/"):
            mans[blob] = dict((k.strip(), v.strip()) for k, v in
                              (l.split(":", 1) for l in jlog.git(repo, "cat-file", "-p", blob).splitlines() if ":" in l))
    led = ledger.Ledger(lines, ledger.roles_of(mans))
    names = {h: m.get("name", h[:12]) for h, m in mans.items()}

    out = ["# Memory: %s" % body, ""]
    out.append("main@%s%s" % (at, "".join(" %s@%s" % (b, c) for b, c in sorted(tips.items()))))
    out.append("")
    out.append("Compiled from the record; `consolidate.py verify --body %s` recomputes it." % body)

    # record
    claimed = who_claimed(repo, at)
    mine = sorted(t for t in {p.split("/")[1] for p in files if p.startswith("done/")} if claimed.get(t) == body)
    rows = []
    for t in mine:
        status = cat("done/%s/status" % t).strip() or "?"
        title = (cat("done/%s/task" % t).strip().splitlines() or [""])[0].lstrip("# ").strip()
        if status not in ("0", "?"):
            last = (cat("done/%s/log" % t).strip().splitlines() or ["(no log)"])[-1]
            rows.append((0, t, "- %s: failed (status %s): %s\n  last log line: `%s`" % (t, status, title, last[:200])))
        else:
            rows.append((1, t, "- %s: done: %s" % (t, title)))
    rows.sort()
    failed = sum(1 for r in rows if r[0] == 0)
    out += ["", "## Record", "", "%d task%s finished, %d failed." % (len(rows), "" if len(rows) == 1 else "s", failed)]
    if rows:
        out += [""] + [r for _, _, r in rows[:budget]]
        if len(rows) > budget:
            out.append("- … %d more" % (len(rows) - budget))

    # forecasts, gate decisions and corrections: from this body's own log
    own = [jlog.parse(l) for b, l in lines if b == body and not jlog.validate(l)]
    fc, briers = [], []
    for j in own:
        if "forecast" not in j.extra:
            continue
        res = led.resolution.get((j.subject, j.question))
        if res:
            y = [1.0 if lab == res[0] else 0.0 for lab in ledger.LABELS]
            b = sum((p - t) ** 2 for p, t in zip(j.p, y))
            briers.append(b)
            fc.append("- %s: said %.2f, world said %s (Brier %.3f)" % (j.extra["forecast"], j.p[2],
                                                                      {1: "yes", -1: "no", 0: "neither"}[res[0]], b))
        else:
            fc.append("- %s: said %.2f, open" % (j.extra["forecast"], j.p[2]))
    out += ["", "## Forecasts", ""]
    if fc:
        out.append("%d made, %d resolved%s." % (len(fc), len(briers),
                                                ", mean Brier %.3f" % (sum(briers) / len(briers)) if briers else ""))
        out += [""] + sorted(fc)[:budget]
    else:
        out.append("None made yet.")

    gates = Counter(j.extra["gate"] for j in own if "gate" in j.extra)
    out += ["", "## Gate", ""]
    out.append(", ".join("%s %d" % kv for kv in sorted(gates.items())) if gates else "No gated judgments yet.")

    corr = []
    for j in own:
        if j.sel not in ("stream", "shadow", "explore") or "forecast" in j.extra:
            continue
        res = led.resolution.get((j.subject, j.question))
        if res and j.judge not in res[2] and argmax(j.p) != res[0]:
            corr.append("- %s said %+d about %s; resolved %+d" % (names.get(j.judge, j.judge[:12]), argmax(j.p),
                                                                 j.subject[:12], res[0]))
    corr = sorted(set(corr))
    out += ["", "## Corrections", ""]
    out += corr[:budget] or ["None on record."]
    if len(corr) > budget:
        out.append("- … %d more" % (len(corr) - budget))
    return "\n".join(out) + "\n"


def pins_of(text):
    m = HEADER.search(text)
    if not m:
        return None, None
    tips = dict(kv.split("@", 1) for kv in m.group(2).split())
    return m.group(1), tips


def main(argv):
    opts, args, it = {"remote": "origin", "budget": "12"}, [], iter(argv)
    for a in it:
        if a.startswith("--"):
            opts[a[2:]] = next(it)
        else:
            args.append(a)
    body = opts.get("body") or os.environ.get("AGENT_ID")
    if not args or args[0] not in ("digest", "publish", "verify") or not body:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repo, remote, budget = os.getcwd(), opts["remote"], int(opts["budget"])
    jlog.git(repo, "fetch", "-q", remote, "+refs/heads/main:refs/remotes/%s/main" % remote)
    path = "bodies/%s/memory.md" % body

    if args[0] == "verify":
        where = opts.get("at", "%s/main" % remote)
        r = jlog.git(repo, "show", "%s:%s" % (where, path), check=False)
        at, tips = pins_of(r)
        if not at:
            print("no memory page for %s at %s" % (body, where), file=sys.stderr)
            return 1
        jlog.log_tips(repo, remote)                      # make sure the pinned log commits are here
        if digest(repo, body, at, tips, budget) != r:
            print("MISMATCH: %s does not follow from its pins" % path)
            return 1
        print("ok: %s follows from main@%s" % (path, at[:12]))
        return 0

    if "at" in opts:
        jlog.log_tips(repo, remote)
        at = jlog.git(repo, "rev-parse", opts["at"] + "^{commit}").strip()
        tips = dict(kv.split("=", 1) for kv in opts.get("tips", "").split(",") if kv)
    else:
        at = jlog.git(repo, "rev-parse", "%s/main" % remote).strip()
        tips = jlog.log_tips(repo, remote)
    text = digest(repo, body, at, tips, budget)
    if args[0] == "digest":
        sys.stdout.write(text)
        return 0
    old = audit.main_file(repo, path, remote)
    strip = lambda t: HEADER.sub("", t or "")
    if old is not None and strip(old) == strip(text):
        print("unchanged")
        return 0
    audit.publish(repo, body, {path: text}, "memory " + body, remote)
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
