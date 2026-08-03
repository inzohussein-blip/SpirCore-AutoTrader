"""Unit tests for the backtester indicators and simulation engine."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))  # bridge/
import backtest as bt  # noqa: E402


class TestIndicators(unittest.TestCase):
    def test_ema_constant(self):
        self.assertAlmostEqual(bt.ema_series([5, 5, 5, 5], 3)[-1], 5.0)

    def test_lsma_linear_endpoint(self):
        # On a perfect line, the LSMA endpoint equals the last value.
        data = [1, 2, 3, 4, 5, 6]
        self.assertAlmostEqual(bt.lsma_endpoint(data, 5, 3), 6.0)

    def test_rsi_rising_market(self):
        closes = list(range(1, 60))  # strictly rising -> RSI near 100
        r = bt.rsi_wilder(closes, 14)
        self.assertGreaterEqual(r[-1], 90.0)
        self.assertLessEqual(r[-1], 100.0)

    def test_macd_zero_on_flat(self):
        closes = [10.0] * 60
        main, sig = bt.macd_series(closes, 12, 26, 9)
        self.assertAlmostEqual(main[-1], 0.0, places=6)

    def test_nw_estimate_flat(self):
        closes = [10.0] * 120
        est = bt.nw_estimate(closes, 119, 100, 8.0, 3.0)
        self.assertIsNotNone(est)
        nw, mae = est
        self.assertAlmostEqual(nw, 10.0)
        self.assertAlmostEqual(mae, 0.0)


class TestEngine(unittest.TestCase):
    def test_simulate_take_profit(self):
        # Buy at close of bar 1 (=10), SL=9 -> risk=1, TP=10+1.5*1=11.5.
        # Bar 2 high=12 >= TP -> exit at 11.5, pnl=1.5 (spread 0).
        n = 5
        bars = bt.Bars(
            "t", [""] * n,
            [10, 10, 11, 11, 11],   # open
            [10, 10, 12, 12, 12],   # high
            [10, 9.5, 10, 11, 11],  # low
            [10, 10, 11, 11, 11],   # close
        )
        sigs = [None, (1, 9.0), None, None, None]
        p = bt.Params(spread_pts=0, tp_coef=1.5)
        pnls = bt.simulate(bars, sigs, p)
        self.assertEqual(len(pnls), 1)
        self.assertAlmostEqual(pnls[0], 1.5)

    def test_simulate_stop_loss(self):
        # Buy at 10, SL=9; bar 2 low=8 <= SL -> exit at 9, pnl=-1.
        n = 4
        bars = bt.Bars(
            "t", [""] * n,
            [10, 10, 9, 9],
            [10, 10, 10, 10],
            [10, 10, 8, 8],
            [10, 10, 9, 9],
        )
        sigs = [None, (1, 9.0), None, None]
        p = bt.Params(spread_pts=0, tp_coef=5.0)  # TP far away so SL triggers
        pnls = bt.simulate(bars, sigs, p)
        self.assertEqual(len(pnls), 1)
        self.assertAlmostEqual(pnls[0], -1.0)

    def test_all_five_strategies_run(self):
        # Smoke: every registered strategy produces a (possibly empty) result.
        bars = bt.load_csv(os.path.join(os.path.dirname(__file__), "sample_bars.csv"))
        p = bt.Params()
        for name, fn in bt.STRATEGIES.items():
            sigs = fn(bars, p)
            self.assertEqual(len(sigs), len(bars), f"{name} misaligned")


if __name__ == "__main__":
    unittest.main()
