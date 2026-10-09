"""Unit tests for gate.py. Run: python3 -m unittest discover -s tests"""
import os, random, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import gate


class Bound(unittest.TestCase):
    def test_matches_the_audit_sampling_table(self):
        # AICPA attribute-sampling table, 95% confidence: 60 clean items -> 4.9%, 150 -> 2.0%,
        # 60 items with one deviation -> 7.7%
        self.assertAlmostEqual(gate.upper_bound(60, 0), 0.049, delta=0.0006)
        self.assertAlmostEqual(gate.upper_bound(150, 0), 0.020, delta=0.0006)
        self.assertAlmostEqual(gate.upper_bound(60, 1), 0.077, delta=0.0006)

    def test_nothing_audited_means_nothing_shown(self):
        self.assertEqual(gate.upper_bound(0, 0), 1.0)
        self.assertEqual(gate.upper_bound(5, 5), 1.0)

    def test_more_evidence_tightens(self):
        self.assertLess(gate.upper_bound(500, 5), gate.upper_bound(100, 1))


class Conformal(unittest.TestCase):
    def test_coverage_holds_on_fresh_items(self):
        rnd = random.Random(3)

        def item():
            a, b = rnd.random(), rnd.random()
            p = sorted([a, b]); p = (p[0], p[1] - p[0], 1 - p[1])
            label = rnd.choices(gate.LABELS, weights=p)[0]
            return p, label
        cal = [item() for _ in range(2000)]
        qhat = gate.calibrate([1 - p[gate.LABELS.index(y)] for p, y in cal], alpha=0.1)
        test = [item() for _ in range(5000)]
        covered = sum(y in gate.prediction_set(p, qhat) for p, y in test) / len(test)
        self.assertGreater(covered, 0.885)

    def test_one_bad_verdict_does_not_blur_the_others(self):
        q = {("all", 1): 0.1, ("all", -1): 0.95}
        rec = {("all", 1): (200, 0), ("all", -1): (200, 100)}
        self.assertEqual(gate.decide((0.05, 0.05, 0.9), ["all"], rec, q, accept=0.05).action, "act")
        self.assertEqual(gate.decide((0.9, 0.05, 0.05), ["all"], rec, q, accept=0.05).reason, "unsure")

    def test_too_few_items_promise_nothing(self):
        self.assertIsNone(gate.calibrate([0.1] * 10, alpha=0.05))
        self.assertEqual(gate.prediction_set((0.0, 0.0, 1.0), None), {-1, 0, 1})


class Decide(unittest.TestCase):
    P = (0.02, 0.03, 0.95)
    Q = {(r, v): 0.2 for r in ("all", "src:tg", "new") for v in (-1, 0, 1)}

    def test_unaudited_region_never_acts(self):
        d = gate.decide(self.P, ["all", "src:tg"], {("all", 1): (500, 0)}, self.Q, accept=0.05)
        self.assertEqual((d.action, d.reason, d.region), ("escalate", "unaudited", "src:tg"))

    def test_audited_everywhere_acts(self):
        rec = {("all", 1): (500, 2), ("src:tg", 1): (150, 0)}
        d = gate.decide(self.P, ["all", "src:tg"], rec, self.Q, accept=0.05)
        self.assertEqual((d.action, d.verdict), ("act", 1))

    def test_too_many_audited_errors_escalates(self):
        rec = {("all", 1): (500, 2), ("src:tg", 1): (60, 5)}
        d = gate.decide(self.P, ["all", "src:tg"], rec, self.Q, accept=0.05)
        self.assertEqual((d.action, d.reason, d.region), ("escalate", "bound", "src:tg"))

    def test_spread_is_unsure_not_neutral(self):
        d = gate.decide((0.45, 0.10, 0.45), ["all"], {("all", 1): (500, 0)}, self.Q, accept=0.05)
        self.assertEqual((d.action, d.reason), ("escalate", "unsure"))

    def test_confident_zero_is_a_verdict(self):
        d = gate.decide((0.02, 0.96, 0.02), ["all"], {("all", 0): (300, 1)}, self.Q, accept=0.05)
        self.assertEqual((d.action, d.verdict), ("act", 0))

    def test_uncalibrated_region_escalates(self):
        q = {k: v for k, v in self.Q.items() if k[0] != "new"}
        d = gate.decide(self.P, ["all", "new"], {("all", 1): (500, 0), ("new", 1): (500, 0)}, q, accept=0.05)
        self.assertEqual(d.reason, "uncalibrated")

    def test_exploration_only_on_reversible_actions(self):
        args = (self.P, ["all"], {}, self.Q)
        self.assertEqual(gate.decide(*args, accept=0.05, reversible=True, eps=1.0).action, "explore")
        self.assertEqual(gate.decide(*args, accept=0.05, reversible=True, eps=1.0).prop, 1.0)
        self.assertEqual(gate.decide(*args, accept=0.05, reversible=False, eps=1.0).action, "escalate")
        hits = sum(gate.decide(*args, accept=0.05, reversible=True, eps=0.1, subject=str(i)).action == "explore"
                   for i in range(2000))
        self.assertTrue(150 < hits < 250, hits)

    def test_exploration_replays_exactly(self):
        self.assertEqual(gate.explore_coin("a", "b"), gate.explore_coin("a", "b"))


class Updates(unittest.TestCase):
    def test_aci_widens_after_a_miss_and_narrows_slowly(self):
        self.assertGreater(gate.aci_step(0.3, covered=False), 0.3)
        self.assertLess(gate.aci_step(0.3, covered=True), 0.3)

    def test_choose_takes_the_cheapest_net_of_information(self):
        costs = {"act": (0.30, 0.0, 0.0), "escalate": (0.02, 0.20, 0.05), "hold": (0.0, 0.5, 0.0)}
        self.assertEqual(gate.choose(costs), "escalate")
        costs["escalate"] = (0.02, 0.40, 0.0)
        self.assertEqual(gate.choose(costs), "act")


if __name__ == "__main__":
    unittest.main()
