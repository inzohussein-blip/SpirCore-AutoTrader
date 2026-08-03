"""Unit tests for the performance analyzer (stdlib unittest, no deps)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))  # bridge/
import analyze  # noqa: E402


class TestStats(unittest.TestCase):
    def test_basic_metrics(self):
        st = analyze.stats_from_pnls([10, -5, 20, -5])
        self.assertEqual(st.trades, 4)
        self.assertEqual(st.wins, 2)
        self.assertEqual(st.losses, 2)
        self.assertAlmostEqual(st.net, 20)
        self.assertAlmostEqual(st.gross_profit, 30)
        self.assertAlmostEqual(st.gross_loss, -10)
        self.assertAlmostEqual(st.profit_factor, 3.0)
        self.assertAlmostEqual(st.win_rate, 50.0)
        self.assertAlmostEqual(st.expectancy, 5.0)

    def test_max_drawdown(self):
        # equity curve: 10, 0, -5, 15 ; running peak: 10,10,10,15
        # drawdown: 0,-10,-15,0 -> worst = -15
        st = analyze.stats_from_pnls([10, -10, -5, 20])
        self.assertAlmostEqual(st.max_drawdown, -15)

    def test_all_wins_infinite_pf(self):
        st = analyze.stats_from_pnls([5, 5, 5])
        self.assertEqual(st.profit_factor, float("inf"))
        self.assertEqual(st.losses, 0)

    def test_empty(self):
        st = analyze.stats_from_pnls([])
        self.assertEqual(st.trades, 0)
        self.assertEqual(st.expectancy, 0.0)
        self.assertEqual(st.win_rate, 0.0)


if __name__ == "__main__":
    unittest.main()
