"""Unit tests for jlog.py's line format. Run: python3 -m unittest discover -s tests"""
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import jlog

S, Q, J = "a" * 40, "b" * 40, "c" * 40


class LineFormat(unittest.TestCase):
    def test_round_trip(self):
        line = jlog.format_line(S, Q, J, (0.1, 0.2, 0.7), "audit", 0.05, ts="2026-10-09T05:00:00Z", blind="1")
        self.assertIsNone(jlog.validate(line))
        j = jlog.parse(line)
        self.assertEqual((j.subject, j.question, j.judge, j.sel, j.prop), (S, Q, J, "audit", 0.05))
        self.assertEqual(j.p, (0.1, 0.2, 0.7))
        self.assertEqual(j.extra, {"blind": "1"})

    def test_rounding_still_sums_to_one(self):
        line = jlog.format_line(S, Q, J, (1 / 3, 1 / 3, 1 / 3))
        self.assertIsNone(jlog.validate(line))
        self.assertAlmostEqual(sum(jlog.parse(line).p), 1.0, places=4)

    def test_v0_reads_as_stream(self):
        line = "2026-10-07T08:00:00\t%s\t%s\tintuition-student-v1\t0.0400\t0.1100\t0.8500" % (S, Q)
        self.assertIsNone(jlog.validate(line))
        j = jlog.parse(line)
        self.assertEqual((j.sel, j.prop, j.judge), ("stream", 1.0, "intuition-student-v1"))

    def test_rejections(self):
        good = jlog.format_line(S, Q, J, (0.1, 0.1, 0.8), ts="2026-10-09T05:00:00Z").split("\t")
        for i, value in [(1, "abc"), (3, "name-in-v2"), (4, "0.5"), (7, "guess"), (8, "0")]:
            f = list(good); f[i] = value
            self.assertIsNotNone(jlog.validate("\t".join(f)), "field %d=%s" % (i, value))
        self.assertIsNotNone(jlog.validate("\t".join(good[:8])))
        self.assertIsNotNone(jlog.validate("\t".join(good + ["Bad=1"])))

    def test_prop_must_be_positive(self):
        with self.assertRaises(ValueError):
            jlog.format_line(S, Q, J, (0, 0, 1), "explore", 1e-9)


if __name__ == "__main__":
    unittest.main()
