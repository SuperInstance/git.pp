"""Unit tests for ledger.py. Run: python3 -m unittest discover -s tests"""
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import jlog, ledger

Q = "f" * 40
ST, L1, L2, W, BIG = "1" * 40, "2" * 40, "3" * 40, "4" * 40, "5" * 40
ROLES = {L1: "labeller", L2: "labeller", W: "world"}
TS = "2026-10-09T06:00:00Z"


def line(subject, judge, p, sel="stream", prop=1.0, **extra):
    return ("b", jlog.format_line(subject.ljust(40, "0"), Q, judge, p, sel, prop, ts=TS, **extra))


def label(subject, judge, p, prop=1.0):
    return line(subject, judge, p, "audit", prop, blind="1", seed="p1")


LINES = [
    line("a", ST, (0.05, 0.05, 0.90)), label("a", L1, (0, 0, 1)),                       # right
    line("a", L1, (0, 0, 1)),                                     # L1 also judged "a": must not score itself
    line("b", ST, (0.05, 0.05, 0.90)), label("b", L1, (1, 0, 0)), label("b", L2, (0.8, 0.1, 0.1)),  # wrong
    line("c", ST, (0.20, 0.30, 0.50)), label("c", L1, (0, 0, 1)), line("c", W, (1, 0, 0)),  # world says -1
    line("d", ST, (0.05, 0.05, 0.90)), label("d", L1, (1, 0, 0)), label("d", L2, (0, 0, 1)),  # split: unresolved
    line("e", ST, (0.05, 0.05, 0.90)), line("e", L1, (1, 0, 0), "audit", 1.0),          # not blind: ignored
    line("7", ST, (0.05, 0.05, 0.90)), label("7", L1, (0, 0, 1), prop=0.5),             # oversampled: weight 2
    line("8", ST, (0.10, 0.10, 0.80), "shadow"), line("8", BIG, (0.9, 0.05, 0.05), "appeal"),
    line("9", ST, (0.10, 0.10, 0.80), "shadow"), line("9", BIG, (0.1, 0.1, 0.8), "appeal"),
]


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.led = ledger.Ledger(LINES, ROLES, tau=0.8)

    def test_resolution_order(self):
        res = self.led.resolution
        self.assertEqual(res[("c".ljust(40, "0"), Q)][0], -1)        # world beats labellers
        self.assertNotIn(("d".ljust(40, "0"), Q), res)                # split labellers resolve nothing
        self.assertNotIn(("e".ljust(40, "0"), Q), res)                # a label that saw verdicts is no label

    def test_scores_weighted_by_propensity(self):
        row = self.led.table()[(ST, Q, "all")]
        self.assertEqual(row["n"], 4)                                 # a, b, c, g
        self.assertAlmostEqual(row["weight"], 5.0)                    # g counts twice
        self.assertAlmostEqual(row["error"], 2 / 5)                   # b and c wrong
        brier_right = 0.05 ** 2 + 0.05 ** 2 + 0.10 ** 2
        brier_b = 0.95 ** 2 + 0.05 ** 2 + 0.90 ** 2
        brier_c = 0.80 ** 2 + 0.30 ** 2 + 0.50 ** 2
        self.assertAlmostEqual(row["brier"], (brier_right * 3 + brier_b + brier_c) / 5)

    def test_gate_record_counts_confident_verdicts_only(self):
        rec = self.led.gate_record(ST, Q)
        self.assertEqual(rec[("all", 1)], (3, 1))                     # a, b, g confident; b wrong; c not confident

    def test_no_judge_is_scored_on_its_own_labels(self):
        judges = {k[0] for k in self.led.table()}
        self.assertNotIn(L1, judges)

    def test_conformal_scores(self):
        sc = self.led.conformal_scores(ST, Q)
        self.assertEqual(sorted(len(v) for k, v in sc.items() if k[0] == "all"), [4])
        self.assertAlmostEqual(min(sc[("all", 1)]), 0.10)

    def test_appeal_value(self):
        self.assertAlmostEqual(self.led.appeal_value(ST), 0.5)        # h changed, i confirmed


class Incremental(unittest.TestCase):
    def test_ingesting_in_two_parts_equals_one_pass(self):
        whole = ledger.Ledger(LINES, ROLES)
        parts = ledger.Ledger(LINES[:7], ROLES).ingest(LINES[7:])
        self.assertEqual(whole.table(), parts.table())
        self.assertEqual(whole.resolution, parts.resolution)
        self.assertEqual(whole.gate_record(ST, Q), parts.gate_record(ST, Q))


class Latest(unittest.TestCase):
    def test_newest_by_time_wins_across_bodies(self):
        s = "c" * 40
        lines = [("zz", jlog.format_line(s, Q, ST, (0.9, 0.05, 0.05), ts="2026-10-09T08:00:00Z")),   # newer, read first
                 ("aa", jlog.format_line(s, Q, ST, (0.05, 0.05, 0.9), ts="2026-10-09T07:00:00Z"))]
        led = ledger.Ledger(lines, ROLES)
        self.assertEqual(led.latest[(ST, s, Q)].p, (0.9, 0.05, 0.05))


class Trend(unittest.TestCase):
    def test_a_labeller_getting_worse_shows_up(self):
        lines = []
        for week, (day, wrong_every) in enumerate([("2026-09-01", 10), ("2026-09-08", 10), ("2026-09-15", 3)]):
            for i in range(30):
                s = "%02x%038x" % (week, i)
                lines.append(("w", jlog.format_line(s, Q, W, (0, 0, 1), ts=day + "T06:00:00Z")))
                p = (1, 0, 0) if i % wrong_every == 0 else (0, 0, 1)
                lines.append(("c", jlog.format_line(s, Q, L1, p, "audit", 1.0, ts=day + "T07:00:00Z", blind="1")))
        trend = ledger.Ledger(lines, ROLES).labeller_trend(L1)
        self.assertEqual([n for _, n, _ in trend], [30, 30, 30])
        self.assertAlmostEqual(trend[0][2], 2 * 3 / 30)            # 3 wrong of 30, Brier 2 each
        self.assertGreater(trend[2][2], 2 * trend[0][2])


if __name__ == "__main__":
    unittest.main()
