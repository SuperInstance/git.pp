#!/usr/bin/env python3
"""window.py -- compile an agent's window: the dense local context for one task, as markdown.

  window.py TASK_FILE [--at COMMIT --tips BODY=COMMIT,...] [--agent BODY] [--budget N] [--out FILE]

Without --at, the window is compiled against the remote's current main and logs. To reproduce an
earlier window exactly, pass the pins from its header: --at <main commit> --tips <body=commit,...>.

Compiled, not searched, and a pure function of its pinned inputs: the main commit and every
judgment-log tip are fixed at the start and written in the header, nothing reads the clock,
and every list is sorted. Two bodies compiling the same task against the same pins produce the
same bytes, so "what did the agent know when it acted?" has an exact answer: store the window
with the result (e.g. done/<task>/window.md) and its hash in the commit.

Sections:
  Charter         bodies/<agent>/charter.md, if the agent has one: what it is for
  Task            verbatim
  What the judges see   the latest judgment per (subject, question, judge) for the task, the
                  hashes it names and the blobs at the paths it names, each read as settled,
                  conflict, ignorance or lean, with judges that disagree marked
  Open questions  unsettled pairs, judge disagreements, and active questions never asked here
  Precedents      done tasks that share an exact blob with this task's zone, failures first
  Recent activity the last commits on main
  Not shown       what the budget cut, with counts
Standard library only.
"""
import hashlib, os, re, sys
from collections import defaultdict
import jlog, ledger
from ledger import argmax

HEX = re.compile(r"\b[0-9a-f]{40}\b")
PATHISH = re.compile(r"(?<![\w/.-])((?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]+)")


def reading(p):
    neg, zero, pos = p
    if pos > 0.6:
        return "settled +"
    if neg > 0.6:
        return "settled -"
    if zero > 0.6:
        return "settled 0"
    if neg > 0.3 and pos > 0.3:
        return "conflict"
    if max(p) < 0.5:
        return "ignorance"
    return "lean"


def tree_blobs(repo, commit):
    """{path: blob} for every file at the commit."""
    out = {}
    for line in jlog.git(repo, "ls-tree", "-r", commit).splitlines():
        meta, path = line.split("\t", 1)
        out[path] = meta.split()[2]
    return out


def compile_window(repo, task_bytes, at, tips, agent=None, budget=12):
    files = tree_blobs(repo, at)
    by_blob = defaultdict(list)
    for path, blob in files.items():
        by_blob[blob].append(path)
    task_text = task_bytes.decode(errors="replace")
    task_blob = jlog.git(repo, "hash-object", "--stdin", data=task_bytes).strip()

    # seeds: the task, the hashes it names, the blobs at the paths it names -- each with its reason
    seeds = {task_blob: "this task"}
    for h in sorted(set(HEX.findall(task_text))):
        seeds.setdefault(h, "named in the task")
    for p in sorted({m.rstrip(".,;:)") for m in PATHISH.findall(task_text)}):
        if p in files:
            seeds.setdefault(files[p], "named in the task")

    lines = list(jlog.iter_log(repo, tips=tips))
    mans_text = {}
    for path, blob in files.items():
        if path.startswith("judges/"):
            mans_text[blob] = dict((k.strip(), v.strip()) for k, v in
                                   (l.split(":", 1) for l in jlog.git(repo, "cat-file", "-p", blob).splitlines() if ":" in l))
    roles = ledger.roles_of(mans_text)
    names = {h: m.get("name", h[:12]) for h, m in mans_text.items()}
    led = ledger.Ledger(lines, roles)

    latest = {}
    for (judge, s, q), j in led.latest.items():
        if s in seeds:
            latest[(s, q, judge)] = j
    questions = {blob: path for path, blob in files.items() if path.startswith("questions/")}

    out = []
    out.append("# Window: %s" % (task_text.splitlines()[0].lstrip("# ").strip() if task_text.strip() else task_blob[:12]))
    out.append("")
    out.append("main@%s · %s · task %s" % (at[:12], " ".join("%s@%s" % (b, c[:12]) for b, c in sorted(tips.items())) or "no judgment logs",
                                           task_blob[:12]))
    shown_counts = {}

    if agent and "bodies/%s/charter.md" % agent in files:
        out += ["", "## Charter", "", jlog.git(repo, "cat-file", "-p", files["bodies/%s/charter.md" % agent]).strip()]

    out += ["", "## Task", "", task_text.strip()]

    # what the judges see
    out += ["", "## What the judges see", ""]
    rows = sorted(latest.items(), key=lambda kv: (kv[0][0] != task_blob, kv[0][0], kv[0][1], kv[0][2]))
    disagree = set()
    by_pair = defaultdict(set)
    for (s, q, judge), j in rows:
        by_pair[(s, q)].add(argmax(j.p))
    disagree = {k for k, v in by_pair.items() if len(v) > 1}
    if rows:
        out.append("| subject | question | judge | -1 | 0 | +1 | reading |")
        out.append("|---|---|---|---|---|---|---|")
        for (s, q, judge), j in rows[:budget]:
            qname = questions.get(q, q[:12])
            note = reading(j.p) + (", judges disagree" if (s, q) in disagree else "")
            out.append("| %s (%s) | %s | %s | %.2f | %.2f | %.2f | %s |" % (
                s[:12], seeds[s], qname, names.get(judge, judge[:12]), j.p[0], j.p[1], j.p[2], note))
        shown_counts["judgments"] = max(0, len(rows) - budget)
    else:
        out.append("No judge has looked at anything in this window yet.")

    # open questions
    out += ["", "## Open questions here", ""]
    opens = []
    for (s, q), verdicts in sorted(by_pair.items()):
        unsettled = [j for (s2, q2, _), j in latest.items() if (s2, q2) == (s, q) and reading(j.p) in ("conflict", "ignorance")]
        if (s, q) in disagree:
            opens.append("- %s about %s: judges disagree" % (questions.get(q, q[:12]), s[:12]))
        elif unsettled:
            opens.append("- %s about %s: %s" % (questions.get(q, q[:12]), s[:12], reading(unsettled[0].p)))
    asked = {q for (_, q) in by_pair}
    for q, path in sorted(questions.items(), key=lambda kv: kv[1]):
        if q not in asked:
            opens.append("- never asked of this task: %s" % path)
    out += opens[:budget] or ["None."]
    shown_counts["open questions"] = max(0, len(opens) - budget)

    # precedents: done tasks sharing an exact blob with the zone
    out += ["", "## Precedents", ""]
    prec = {}
    for blob, why in seeds.items():
        for path in by_blob.get(blob, []):
            m = re.match(r"done/([^/]+)/", path)
            if m and m.group(1) not in prec:
                prec[m.group(1)] = (why, path)
    prec_rows = []
    for t, (why, path) in prec.items():
        status_blob = files.get("done/%s/status" % t)
        status = jlog.git(repo, "cat-file", "-p", status_blob).strip() if status_blob else "?"
        failed = status not in ("0", "?")
        prec_rows.append((not failed, t, "- %s: %s; linked by %s (%s)" % (t, "failed (status %s)" % status if failed else "done", path, why)))
    prec_rows.sort()
    out += [r for _, _, r in prec_rows[:budget]] or ["None linked exactly."]
    shown_counts["precedents"] = max(0, len(prec_rows) - budget)

    out += ["", "## Recent activity", ""]
    out += ["- " + l for l in jlog.git(repo, "log", "-6", "--format=%h %s", at).splitlines()]

    cut = {k: v for k, v in shown_counts.items() if v}
    out += ["", "## Not shown", ""]
    out += ["- %d more %s" % (v, k) for k, v in sorted(cut.items())] or ["Nothing: everything linked fits."]
    text = "\n".join(out) + "\n"
    return text, hashlib.sha1(text.encode()).hexdigest()


def main(argv):
    opts, args, it = {"remote": "origin", "budget": "12"}, [], iter(argv)
    for a in it:
        if a.startswith("--"):
            opts[a[2:]] = next(it)
        else:
            args.append(a)
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repo = os.getcwd()
    if "at" in opts:
        jlog.log_tips(repo, opts["remote"])                  # make sure the pinned objects are here
        at = jlog.git(repo, "rev-parse", opts["at"] + "^{commit}").strip()
        tips = dict(kv.split("=", 1) for kv in opts.get("tips", "").split(",") if kv)
        tips = {b: jlog.git(repo, "rev-parse", c + "^{commit}").strip() for b, c in tips.items()}
    else:
        jlog.git(repo, "fetch", "-q", opts["remote"], "+refs/heads/main:refs/remotes/%s/main" % opts["remote"])
        at = jlog.git(repo, "rev-parse", "%s/main" % opts["remote"]).strip()
        tips = jlog.log_tips(repo, opts["remote"])
    text, _ = compile_window(repo, open(args[0], "rb").read(), at, tips, opts.get("agent"), int(opts["budget"]))
    if "out" in opts:
        with open(opts["out"], "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
