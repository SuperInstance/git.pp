"""Unit tests for shipgate.py. Run: python3 -m unittest discover -s tests"""
import os, random, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import jlog, ledger, shipgate

Q = "f" * 40
A, B, C, D, LAB = "a" * 40, "b" * 40, "c" * 40, "d" * 40, "e" * 40
ROLES = {LAB: "labeller"}
P = {1: (0.05, 0.05, 0.90), -1: (0.90, 0.05, 0.05)}


def subj(region, i):
    return ("%x" % (region + 1)) + ("%039x" % i)


def regions_of(subject, question):
    return ["all", "r%s" % subject[0]]


def ln(subject, judge, verdict, sel="stream", ts="2026-10-09T06:00:00Z", **extra):
    return ("x", jlog.format_line(subject, Q, judge, P[verdict], sel, 1.0, ts=ts, **extra))


def world(changes):
    """300 items in regions r1-r3, truth +1. A is right on all but every tenth item. `changes`
    maps (region, i) -> B's verdict where it differs from A's."""
    lines = []
    for region in range(3):
        for i in range(100):
            s = subj(region, i)
            lines.append(ln(s, LAB, 1, "audit", blind="1"))
            a = -1 if i % 10 == 0 else 1
            lines.append(ln(s, A, a))
            lines.append(ln(s, B, changes.get((region, i), a)))
    return lines


class Churn(unittest.TestCase):
    def test_net_gain_that_breaks_a_region_is_blocked(self):
        fixes = {(0, i): 1 for i in range(0, 100, 10)}              # fixes all 10 errors in r1...
        breaks = {(0, i): -1 for i in range(1, 6)}                  # ...and breaks 5 good items there
        led = ledger.Ledger(world({**fixes, **breaks}), ROLES, regions_of)
        rows, blocked = shipgate.churn(led, A, B)
        self.assertEqual((rows["r1"]["fixed"], rows["r1"]["broken"]), (10, 5))   # net +5 in r1 itself
        self.assertEqual(blocked, ["r1"])                         # "all": 5 of 300 is within 2%

    def test_small_breakage_ships(self):
        led = ledger.Ledger(world({(0, 0): 1, (1, 1): -1}), ROLES, regions_of)
        self.assertEqual(shipgate.churn(led, A, B)[1], [])


class Diff(unittest.TestCase):
    def test_flags_the_region_that_moved(self):
        moved = {(2, i): -1 for i in range(1, 40) if i % 10}
        rows, flagged = shipgate.diff(world(moved), A, B, regions_of)
        self.assertEqual(flagged, ["r3"])
        self.assertEqual(rows["r1"]["flips"], 0)


class Polarization(unittest.TestCase):
    def build(self, shared):
        rnd = random.Random(5)
        lines = []
        for i in range(2000):
            s = subj(0, i)
            lines.append(ln(s, LAB, 1, "audit", blind="1"))
            hard = rnd.random() < 0.2
            for jd in (A, C, D):
                wrong = hard if shared else rnd.random() < 0.2
                lines.append(ln(s, jd, -1 if wrong else 1))
        return ledger.Ledger(lines, ROLES, regions_of)

    def test_independent_judges_sit_near_one(self):
        r = shipgate.polarization(self.build(shared=False), [A, C, D])["ratio"]
        self.assertTrue(0.6 < r < 1.6, r)

    def test_a_shared_blind_spot_stands_out(self):
        r = shipgate.polarization(self.build(shared=True), [A, C, D])["ratio"]
        self.assertGreater(r, 10)


class Drift(unittest.TestCase):
    def build(self, new_flips):
        lines = []
        for i in range(200):
            s = subj(0, i)
            before = i < 100
            ts = "2026-10-01T00:00:00Z" if before else "2026-10-08T00:00:00Z"
            a = 1 if before else (-1 if i % 2 else 1)              # the world changed: half are bad now
            lines.append(ln(s, A, a, ts=ts))
            if not before:
                lines.append(ln(s, B, -a if new_flips else a, ts="2026-10-09T00:00:00Z"))
        return lines

    def test_world_change_without_model_change(self):
        d = shipgate.drift(self.build(False), A, B, "2026-10-05T00:00:00Z")
        self.assertAlmostEqual(d["world_drift"], 0.5)
        self.assertEqual(d["model_drift"], 0.0)

    def test_model_change_is_separated(self):
        d = shipgate.drift(self.build(True), A, B, "2026-10-05T00:00:00Z")
        self.assertAlmostEqual(d["world_drift"], 0.5)
        self.assertEqual(d["model_drift"], 1.0)


if __name__ == "__main__":
    unittest.main()
