"""Unit tests for gatekeep.py's pure planning step. Run: python3 -m unittest discover -s tests"""
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import gatekeep, jlog, ledger

Q, ST, LAB = "f" * 40, "1" * 40, "2" * 40


def audited_world(wrong_every):
    lines = []
    for i in range(300):
        s = "%040x" % i
        lines.append(("c", jlog.format_line(s, Q, LAB, (0, 0, 1), "audit", 1.0, blind="1")))
        p = (0.9, 0.05, 0.05) if wrong_every and i % wrong_every == 0 else (0.03, 0.02, 0.95)
        lines.append(("o", jlog.format_line(s, Q, ST, p, regions="all,src:tg")))
    return ledger.Ledger(lines, {LAB: "labeller"})


class Plan(unittest.TestCase):
    POL = gatekeep.read_policy("accept: default 0.05\nexplore: 0\nbypass: 0\n")

    def test_acts_where_audited_and_logs_why(self):
        d, line = gatekeep.plan((0.03, 0.02, 0.95), ["all", "src:tg"], audited_world(0), self.POL, ST, Q, "a" * 40)
        self.assertEqual(d.action, "act")
        j = jlog.parse(line)
        self.assertEqual((j.sel, j.extra["gate"], j.extra["regions"], j.extra["cfg"]),
                         ("stream", "act", "all,src:tg", self.POL["cfg"]))

    def test_escalates_into_a_shadow_line_in_an_unaudited_region(self):
        d, line = gatekeep.plan((0.03, 0.02, 0.95), ["all", "src:email"], audited_world(0), self.POL, ST, Q, "a" * 40)
        self.assertEqual(d.action, "escalate")
        self.assertIn(d.reason, ("uncalibrated", "unaudited"))         # either way: no evidence there yet
        self.assertEqual(jlog.parse(line).sel, "shadow")

    def test_bypass_is_logged_with_its_probability(self):
        pol = gatekeep.read_policy("bypass: 1\n")
        d, line = gatekeep.plan((0.03, 0.02, 0.95), ["all"], audited_world(0), pol, ST, Q, "a" * 40)
        self.assertEqual(d.action, "bypass")
        self.assertEqual(jlog.parse(line).extra["gate_p"], "1")

    def test_exploration_logs_its_propensity(self):
        pol = gatekeep.read_policy("explore: 1\nbypass: 0\n")
        d, line = gatekeep.plan((0.03, 0.02, 0.95), ["all", "new"], audited_world(0), pol, ST, Q, "a" * 40, reversible=True)
        j = jlog.parse(line)
        self.assertEqual((d.action, j.sel, j.prop), ("explore", "explore", 1.0))

    def test_config_hash_changes_with_policy(self):
        self.assertNotEqual(gatekeep.read_policy("explore: 0.02")["cfg"], gatekeep.read_policy("explore: 0.03")["cfg"])
        self.assertEqual(gatekeep.read_policy("")["cfg"], gatekeep.read_policy("# nothing\n")["cfg"])


if __name__ == "__main__":
    unittest.main()
