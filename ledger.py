#!/usr/bin/env python3
"""ledger.py -- track records for every judge, scored only on evidence it did not produce.

Resolution of an item (subject, question), strongest evidence first:
  1. a `world` judge's verdict (a test result, an override, a sensor): outcomes no model produced;
  2. otherwise the mean of blind labeller verdicts (sel=audit with blind=1, judge role labeller).
A judge is never scored on an item resolved by its own lines, and labels that a judge saw before
answering (drills, appeals) never count as resolutions.

For each (judge, question, region) the ledger reports, weighted by inverse selection propensity
so oversampled strata do not distort the estimate:
  brier      mean Brier score of the judge's probabilities against the resolution
  error      share of resolved items where the judge's top verdict was wrong
and, for the gate, raw audited counts of confident verdicts and the conformal scores.

  ledger.py [--tau T] [--remote R]   print every judge's record, worst Brier first
Judge roles come from manifests under judges/ on main (`role: judge | labeller | world`).
Standard library only.
"""
import os, sys
from collections import defaultdict
import jlog
from gate import LABELS, upper_bound


def default_regions(subject, question):
    return ["all", "q:" + question[:12]]


def manifests(repo, remote="origin"):
    """{blob hash of manifest: {field: value}} for every file under judges/ on main."""
    out = {}
    listing = jlog.git(repo, "ls-tree", "-r", "%s/main" % remote, "--", "judges/", check=False)
    for line in listing.splitlines():
        _, _, blob, path = line.split(None, 3)
        fields = {"path": path}
        for l in jlog.git(repo, "cat-file", "-p", blob).splitlines():
            if ":" in l:
                k, v = l.split(":", 1)
                fields[k.strip()] = v.strip()
        out[blob] = fields
    return out


def argmax(p):
    return LABELS[max(range(3), key=lambda i: p[i])]


class Ledger:
    def __init__(self, lines, roles, regions_of=default_regions, tau=0.8):
        """lines: iterable of (body, line); roles: {judge hash: role}."""
        self.roles, self.regions_of, self.tau = roles, regions_of, tau
        latest = {}                          # (judge, subject, question) -> Judgment, last stream/shadow/explore
        labels = defaultdict(list)           # (subject, question) -> [(p, prop, judge)]
        world = {}
        appeals = defaultdict(list)          # (subject, question) -> [Judgment] from appeal judges
        for body, line in lines:
            if jlog.validate(line):
                continue
            j = jlog.parse(line)
            key = (j.subject, j.question)
            role = roles.get(j.judge, "judge")
            if role == "world":
                world[key] = j
            elif role == "labeller" and j.sel == "audit" and j.extra.get("blind") == "1":
                labels[key].append((j.p, j.prop, j.judge))
            elif j.sel == "appeal":
                appeals[key].append(j)
            elif j.sel in ("stream", "shadow", "explore"):
                latest[(j.judge, j.subject, j.question)] = j
        self.resolution = {}                 # key -> (label, weight, resolvers)
        for key, j in world.items():
            self.resolution[key] = (argmax(j.p), 1.0, {j.judge})
        for key, ls in labels.items():
            if key in self.resolution:
                continue
            mean = [sum(p[i] for p, _, _ in ls) / len(ls) for i in range(3)]
            top = sorted(mean, reverse=True)
            if top[0] - top[1] < 1e-9:
                continue                     # labellers split evenly: unresolved
            prop = min(pr for _, pr, _ in ls)
            self.resolution[key] = (argmax(mean), 1.0 / prop, {jd for _, _, jd in ls})
        self.latest, self.appeals = latest, appeals

    def scored(self):
        """Yield (judge, question, regions, judgment, label, weight) for every resolved item."""
        for (judge, s, q), j in sorted(self.latest.items()):
            res = self.resolution.get((s, q))
            if res is None or judge in res[2]:
                continue                     # unresolved, or resolved by this judge itself
            yield judge, q, self.regions_of(s, q), j, res[0], res[1]

    def table(self):
        """{(judge, question, region): dict(n, brier, error, weight)}."""
        acc = defaultdict(lambda: [0, 0.0, 0.0, 0.0])
        for judge, q, regions, j, label, w in self.scored():
            y = [1.0 if lab == label else 0.0 for lab in LABELS]
            brier = sum((p - t) ** 2 for p, t in zip(j.p, y))
            wrong = 1.0 if argmax(j.p) != label else 0.0
            for r in regions:
                a = acc[(judge, q, r)]
                a[0] += 1; a[1] += w * brier; a[2] += w * wrong; a[3] += w
        return {k: {"n": a[0], "brier": a[1] / a[3], "error": a[2] / a[3], "weight": a[3]} for k, a in acc.items()}

    def gate_record(self, judge, question, confident=None):
        """{(region, verdict): (n_audited, n_wrong)} of confident verdicts, for gate.decide.
        `confident(p)` decides which verdicts count; by default the top probability >= tau."""
        confident = confident or (lambda p: max(p) >= self.tau)
        rec = defaultdict(lambda: [0, 0])
        for jd, q, regions, j, label, _ in self.scored():
            if jd != judge or q != question or not confident(j.p):
                continue
            v = argmax(j.p)
            for r in regions:
                rec[(r, v)][0] += 1
                rec[(r, v)][1] += int(v != label)
        return {k: tuple(v) for k, v in rec.items()}

    def conformal_scores(self, judge, question):
        """{(region, verdict): [1 - p(label)]}: Mondrian calibration data for the gate, split by
        the judge's top verdict so each kind of verdict earns its own threshold."""
        out = defaultdict(list)
        for jd, q, regions, j, label, _ in self.scored():
            if jd == judge and q == question:
                for r in regions:
                    out[(r, argmax(j.p))].append(1 - j.p[LABELS.index(label)])
        return dict(out)

    def qhats(self, judge, question, alpha=0.05):
        """{(region, verdict): threshold or None} ready for gate.decide."""
        from gate import calibrate
        return {k: calibrate(v, alpha) for k, v in self.conformal_scores(judge, question).items()}

    def appeal_value(self, judge):
        """Share of appealed items where the higher judge disagreed with this judge's shadow
        verdict. Near 0: escalations are wasted on the higher judge. Near 1: the judge is weak."""
        changed = total = 0
        for (s, q), js in self.appeals.items():
            mine = self.latest.get((judge, s, q))
            if mine is None or mine.sel != "shadow":
                continue
            total += 1
            changed += int(argmax(js[-1].p) != argmax(mine.p))
        return changed / total if total else None


def main(argv):
    opts, it = {"remote": "origin", "tau": "0.8"}, iter(argv)
    for a in it:
        if a.startswith("--"):
            opts[a[2:]] = next(it)
    repo = os.getcwd()
    jlog.git(repo, "fetch", "-q", opts["remote"], "+refs/heads/main:refs/remotes/%s/main" % opts["remote"])
    mans = manifests(repo, opts["remote"])
    roles = {h: m.get("role", "judge") for h, m in mans.items()}
    names = {h: m.get("name", h[:12]) for h, m in mans.items()}
    led = Ledger(jlog.iter_log(repo, remote=opts["remote"]), roles, tau=float(opts["tau"]))
    rows = sorted(led.table().items(), key=lambda kv: -kv[1]["brier"])
    print("%-24s %-12s %-16s %5s %7s %7s" % ("judge", "question", "region", "n", "brier", "error"))
    for (judge, q, r), v in rows:
        print("%-24s %-12s %-16s %5d %7.3f %7.3f" % (names.get(judge, judge[:12]), q[:12], r, v["n"], v["brier"], v["error"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
