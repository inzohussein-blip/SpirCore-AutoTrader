"""Unit tests for the XAUUSD Time Machine (pure, no MT5, deterministic)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))  # bridge/

import timemachine as tm  # noqa: E402

_FIX = os.path.join(os.path.dirname(__file__), "sample_bars.csv")


def _trend(start: float, step: float, n: int) -> list:
    """A clean monotonic series of OHLC bars (each bar moves by `step`)."""
    bars, c = [], start
    for _ in range(n):
        o = c
        c = o + step
        hi, lo = max(o, c) + abs(step) * 0.1, min(o, c) - abs(step) * 0.1
        bars.append({"open": o, "high": hi, "low": lo, "close": c})
    return bars


class TestPureHelpers(unittest.TestCase):
    def test_hit_stop_before_target(self):
        # A buy candle that touches BOTH counts as the stop (conservative).
        self.assertEqual(tm._hit("buy", sl=99, tp=101, high=102, low=98), "stop")
        self.assertEqual(tm._hit("buy", sl=99, tp=101, high=102, low=100), "target")
        self.assertIsNone(tm._hit("buy", sl=99, tp=101, high=100.5, low=99.5))

    def test_validate(self):
        self.assertIsNone(tm._validate(100, 95, 110, "buy"))
        self.assertIsNone(tm._validate(100, 105, 90, "sell"))
        self.assertIsNotNone(tm._validate(100, 105, 110, "buy"))   # sl above entry
        self.assertIsNotNone(tm._validate(100, 95, 110, "flat"))   # bad direction


class TestSimulate(unittest.TestCase):
    def setUp(self):
        self.bars = tm.load_bars_csv(_FIX)

    def test_probabilities_sum_to_one(self):
        r = tm.simulate(self.bars, entry=3350, sl=3344, tp=3362,
                        direction="buy", n_sims=2000, seed=19)
        self.assertTrue(r["ok"])
        total = r["p_target"] + r["p_stop"] + r["p_open"]
        self.assertAlmostEqual(total, 1.0, places=2)

    def test_deterministic(self):
        a = tm.simulate(self.bars, 3350, 3344, 3362, "buy", n_sims=3000, seed=7)
        b = tm.simulate(self.bars, 3350, 3344, 3362, "buy", n_sims=3000, seed=7)
        self.assertEqual(a["p_target"], b["p_target"])
        self.assertEqual(a["p_stop"], b["p_stop"])

    def test_nearer_target_more_likely(self):
        near = tm.simulate(self.bars, 3350, 3344, 3353, "buy", n_sims=4000, seed=19)
        far = tm.simulate(self.bars, 3350, 3344, 3380, "buy", n_sims=4000, seed=19)
        self.assertGreaterEqual(near["p_target"], far["p_target"])

    def test_invalid_plan(self):
        r = tm.simulate(self.bars, 3350, 3360, 3362, "buy", n_sims=100)
        self.assertFalse(r["ok"])

    def test_small_pool_refused(self):
        r = tm.simulate(self.bars[:5], 3350, 3344, 3362, "buy", n_sims=100)
        self.assertFalse(r["ok"])

    def test_uptrend_favors_buy_target(self):
        up = _trend(3000, +1.0, 120)
        r = tm.simulate(up, entry=3000, sl=2994, tp=3012, direction="buy",
                        n_sims=2000, seed=19)
        self.assertGreater(r["p_target"], r["p_stop"])

    def test_downtrend_favors_buy_stop(self):
        down = _trend(3000, -1.0, 120)
        r = tm.simulate(down, entry=3000, sl=2994, tp=3012, direction="buy",
                        n_sims=2000, seed=19)
        self.assertGreater(r["p_stop"], r["p_target"])


class TestReplay(unittest.TestCase):
    def test_counts_sum_to_trials(self):
        bars = tm.load_bars_csv(_FIX)
        r = tm.replay(bars, 3350, 3344, 3362, "buy", horizon=48)
        self.assertTrue(r["ok"])
        self.assertEqual(r["target"] + r["stop"] + r["open"], r["trials"])


class TestRun(unittest.TestCase):
    def test_bundle_has_history_and_disclaimer(self):
        bars = tm.load_bars_csv(_FIX)
        r = tm.run(bars, 3350, 3344, 3362, "buy", n_sims=1000, seed=19)
        self.assertTrue(r["ok"])
        self.assertIn("history", r)
        self.assertIn("not a profit guarantee", r["disclaimer"])
        self.assertIn("verdict", r)


if __name__ == "__main__":
    unittest.main()
