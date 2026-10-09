#!/usr/bin/env python3
"""shipgate.py -- decide whether a new judge may replace an old one, from the logs alone.

A new judge can improve on average and still break a population. So a release is judged by
what it does to each region, not by its net score:

  shipgate.py churn --old A --new B [--question Q] [--max-broken N] [--max-share F]
      On items resolved by evidence neither judge produced, count per region the items the new
      judge fixed and the items it newly broke. Blocks (exit 1) if any region breaks more than
      N items or more than share F of its resolved items, even when the net change is positive.
  shipgate.py diff --old A --new B [--question Q]
      No labels needed: per region, how often the new judge's top verdict differs from the old
      one's on the same items. Flags regions that move far more than the rest:
      "who does the new judge treat differently?", answerable before release.
  shipgate.py polarization J1 J2 J3 ... [--question Q]
      On resolved items every listed judge answered, compare how often they are all wrong
      with what independence predicts. A ratio well above 1 is a shared blind spot.
  shipgate.py drift --old A --new B --split TS [--question Q]
      Old judges are pure functions, so run the old judge on new content too. Change in the old
      judge's verdict mix across the split is change in the world; the old and new judges'
      disagreement on the same new content is change in the model.

  shipgate.py canary --cfg-old X --cfg-new Y
      Rubric, question and threshold changes are content, and need the same staging as new
      weights. Compares decisions logged under two gate configurations (cfg= on each line):
      per region, the share acted on and the error rate of acted items that were later
      resolved. Blocks (exit 1) where the new configuration's acted error rate is clearly worse.
  shipgate.py independence --judge J --labeller L
      Before trusting L to label J's work: on items a third party resolved, how often both are
      wrong, against what independence predicts, and how often they then pick the same wrong
      answer. More accurate models make more correlated errors; a judge's own teacher is the
      least independent labeller there is.

Every report names the consumers of the judge listed in soul/consumers (lines of
`<judge name or hash> <consumer> [what it does]`), so a change reaches everything that inherits it.

Regions are the ledger's (judge-independent). Standard library only.
"""
import math, os, sys
from collections import Counter, defaultdict
import jlog, ledger
from ledger import argmax

DEFAULT_MAX_BROKEN, DEFAULT_MAX_SHARE = 3, 0.02


def verdicts(lines, judges, question=None):
    """{(subject, question): {judge: Judgment}} with each judge's latest non-audit line."""
    out = defaultdict(dict)
    for _, line in lines:
        if jlog.validate(line):
            continue
        j = jlog.parse(line)
        if j.judge in judges and j.sel in ("stream", "shadow", "explore") and (question is None or j.question == question):
            out[(j.subject, j.question)][j.judge] = j
    return out


def churn(led, old, new, question=None, max_broken=DEFAULT_MAX_BROKEN, max_share=DEFAULT_MAX_SHARE):
    """Per region: resolved items both judged, fixed, broken. Returns (rows, blocked_regions)."""
    rows = defaultdict(lambda: {"n": 0, "fixed": 0, "broken": 0})
    for key, (label, _, resolvers) in led.resolution.items():
        s, q = key
        if question and q != question or old in resolvers or new in resolvers:
            continue
        a, b = led.latest.get((old, s, q)), led.latest.get((new, s, q))
        if a is None or b is None:
            continue
        a_ok, b_ok = argmax(a.p) == label, argmax(b.p) == label
        for r in led.regions_of(s, q):
            row = rows[r]
            row["n"] += 1
            row["fixed"] += int(b_ok and not a_ok)
            row["broken"] += int(a_ok and not b_ok)
    blocked = sorted(r for r, v in rows.items() if v["broken"] > max(max_broken, max_share * v["n"]))
    return dict(rows), blocked


def diff(lines, old, new, regions_of=ledger.default_regions, question=None, z=3.0):
    """Per region: items both judged and verdict flips. Flags regions whose flip rate sits more
    than z standard errors above the overall rate."""
    v = verdicts(lines, {old, new}, question)
    rows = defaultdict(lambda: [0, 0])
    for (s, q), by in v.items():
        if old in by and new in by:
            flip = int(argmax(by[old].p) != argmax(by[new].p))
            for r in regions_of(s, q):
                rows[r][0] += 1
                rows[r][1] += flip
    total = rows.get("all") or [sum(n for n, _ in rows.values()), sum(f for _, f in rows.values())]
    base = total[1] / total[0] if total[0] else 0.0
    flagged = []
    for r, (n, f) in rows.items():
        if n and r != "all":
            se = math.sqrt(max(base * (1 - base), 1e-9) / n)
            if (f / n - base) / se > z:
                flagged.append(r)
    return {r: {"n": n, "flips": f} for r, (n, f) in rows.items()}, sorted(flagged)


def polarization(led, judges, question=None):
    """Observed all-wrong count, expected under independence, and their ratio, on resolved items
    that every listed judge answered and none of them resolved."""
    items = []
    for (s, q), (label, _, resolvers) in led.resolution.items():
        if question and q != question or resolvers & set(judges):
            continue
        js = [led.latest.get((jd, s, q)) for jd in judges]
        if all(js):
            items.append([argmax(j.p) != label for j in js])
    n = len(items)
    if not n:
        return {"n": 0, "all_wrong": 0, "expected": 0.0, "ratio": None}
    rates = [sum(it[i] for it in items) / n for i in range(len(judges))]
    expected = n * math.prod(rates)
    observed = sum(all(it) for it in items)
    return {"n": n, "all_wrong": observed, "expected": expected,
            "ratio": observed / expected if expected > 0 else (math.inf if observed else None),
            "error_rates": rates}


def drift(lines, old, new, split_ts, question=None):
    """World drift: how the old judge's verdict mix moved across split_ts. Model drift: how often
    the old and new judges disagree on content from after the split."""
    split = jlog.utc(split_ts)
    before, after, both, disagree = Counter(), Counter(), 0, 0
    firsts = {}
    v = defaultdict(dict)
    for _, line in lines:
        if jlog.validate(line):
            continue
        j = jlog.parse(line)
        if question and j.question != question or j.sel not in ("stream", "shadow", "explore"):
            continue
        k = (j.subject, j.question)
        ts = jlog.utc(j.ts)
        if j.judge == old:                 # when content first appeared: the old judge saw it first
            firsts[k] = min(firsts.get(k, ts), ts)
        if j.judge in (old, new):
            v[k][j.judge] = j
    for k, by in v.items():
        if old not in by or k not in firsts:
            continue
        side = before if firsts[k] < split else after
        side[argmax(by[old].p)] += 1
        if firsts[k] >= split and new in by:
            both += 1
            disagree += int(argmax(by[old].p) != argmax(by[new].p))

    def mix(c):
        t = sum(c.values())
        return {lab: c[lab] / t for lab in (-1, 0, 1)} if t else {}
    mb, ma = mix(before), mix(after)
    world = 0.5 * sum(abs(mb.get(l, 0) - ma.get(l, 0)) for l in (-1, 0, 1)) if mb and ma else None
    return {"world_drift": world, "model_drift": disagree / both if both else None,
            "before": mb, "after": ma, "n_before": sum(before.values()), "n_after": sum(after.values()), "n_both": both}


def canary(led, cfg_old, cfg_new, z=2.0):
    """Per region: for each configuration, items decided, share acted, acted-and-resolved, acted
    errors. A region blocks when the new acted error rate exceeds the old by more than z
    standard errors."""
    rows = defaultdict(lambda: {c: [0, 0, 0, 0] for c in (cfg_old, cfg_new)})
    for (judge, s, q), j in led.latest.items():
        cfg = j.extra.get("cfg")
        if cfg not in (cfg_old, cfg_new):
            continue
        acted = j.extra.get("gate") == "act"
        res = led.resolution.get((s, q))
        for r in ledger.regions_on(j) or led.regions_of(s, q):
            a = rows[r][cfg]
            a[0] += 1
            a[1] += int(acted)
            if acted and res is not None and judge not in res[2]:
                a[2] += 1
                a[3] += int(argmax(j.p) != res[0])
    blocked = []
    for r, by in rows.items():
        (_, _, n0, e0), (_, _, n1, e1) = by[cfg_old], by[cfg_new]
        if n0 and n1:
            p0, p1, pool = e0 / n0, e1 / n1, (e0 + e1) / (n0 + n1)
            se = math.sqrt(max(pool * (1 - pool), 1e-9) * (1 / n0 + 1 / n1))
            if (p1 - p0) / se > z:
                blocked.append(r)
    return {r: {c: dict(zip(("n", "acted", "resolved", "errors"), v)) for c, v in by.items()} for r, by in rows.items()}, sorted(blocked)


def independence(led, judge, labeller):
    """On items resolved by neither: both-wrong count against independence, and how often two
    wrong answers coincide (chance is 1/2: there are two wrong labels)."""
    n = jw = lw = both = same = 0
    for (s, q), (label, _, resolvers) in led.resolution.items():
        if judge in resolvers or labeller in resolvers:
            continue
        a, b = led.latest.get((judge, s, q)), led.latest.get((labeller, s, q))
        if a is None or b is None:
            continue
        n += 1
        wa, wb = argmax(a.p) != label, argmax(b.p) != label
        jw += wa; lw += wb
        if wa and wb:
            both += 1
            same += int(argmax(a.p) == argmax(b.p))
    expected = n * (jw / n) * (lw / n) if n else 0.0
    return {"n": n, "judge_errors": jw, "labeller_errors": lw, "both_wrong": both,
            "expected_both_wrong": expected, "ratio": both / expected if expected else None,
            "same_wrong_answer": same / both if both else None}


def consumers(repo, judge, names, remote="origin"):
    text = jlog.git(repo, "show", "%s/main:soul/consumers" % remote, check=False)
    keys = {judge, names.get(judge, "")}
    return [l.split(None, 1)[1] for l in text.splitlines() if l.strip() and not l.startswith("#") and l.split()[0] in keys]


def main(argv):
    opts, args, it = {"remote": "origin"}, [], iter(argv)
    for a in it:
        if a.startswith("--"):
            opts[a[2:]] = next(it)
        else:
            args.append(a)
    if not args or args[0] not in ("churn", "diff", "polarization", "drift", "canary", "independence"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repo, q = os.getcwd(), opts.get("question")
    jlog.git(repo, "fetch", "-q", opts["remote"], "+refs/heads/main:refs/remotes/%s/main" % opts["remote"])
    mans = ledger.manifests(repo, opts["remote"])
    roles, names = ledger.roles_of(mans), {h: m.get("name", "") for h, m in mans.items()}
    lines = list(jlog.iter_log(repo, remote=opts["remote"]))
    for jd in [opts.get("old"), opts.get("judge")]:
        for c in consumers(repo, jd, names, opts["remote"]) if jd else []:
            print("consumer of %s: %s" % (names.get(jd) or jd[:12], c))
    if args[0] == "canary":
        rows, blocked = canary(ledger.Ledger(lines, roles), opts["cfg-old"], opts["cfg-new"])
        for r, by in sorted(rows.items()):
            print("%-20s %s%s" % (r, "  ".join("%s: n=%d acted=%d resolved=%d errors=%d" % (c, v["n"], v["acted"], v["resolved"], v["errors"])
                                               for c, v in sorted(by.items())), "  BLOCK" if r in blocked else ""))
        print("BLOCKED" if blocked else "ok to roll out")
        return 1 if blocked else 0
    if args[0] == "independence":
        print(independence(ledger.Ledger(lines, roles), opts["judge"], opts["labeller"]))
        return 0
    if args[0] == "churn":
        led = ledger.Ledger(lines, roles)
        rows, blocked = churn(led, opts["old"], opts["new"], q, int(opts.get("max-broken", DEFAULT_MAX_BROKEN)),
                              float(opts.get("max-share", DEFAULT_MAX_SHARE)))
        for r, v in sorted(rows.items()):
            print("%-20s n=%-6d fixed=%-5d broken=%-5d%s" % (r, v["n"], v["fixed"], v["broken"], "  BLOCK" if r in blocked else ""))
        print("BLOCKED" if blocked else "ok to ship")
        return 1 if blocked else 0
    if args[0] == "diff":
        rows, flagged = diff(lines, opts["old"], opts["new"], question=q)
        for r, v in sorted(rows.items()):
            print("%-20s n=%-6d flips=%-5d%s" % (r, v["n"], v["flips"], "  MOVED" if r in flagged else ""))
        return 0
    if args[0] == "polarization":
        led = ledger.Ledger(lines, roles)
        res = polarization(led, args[1:], q)
        print(res)
        return 0
    res = drift(lines, opts["old"], opts["new"], opts["split"], q)
    print(res)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
