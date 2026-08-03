#!/usr/bin/env python3
"""
SpirCore-AutoTrader :: Performance analyzer

Reads the EA's trade journal CSV (spircore_journal.csv, written by
SpirCore_EA on every closed deal) and prints a professional performance
report: win rate, profit factor, expectancy, and maximum drawdown.

These are the numbers that actually tell you whether a strategy has an
edge -- a high win rate with a terrible profit factor is a losing system.

Usage:
    python analyze.py [path/to/spircore_journal.csv]

Dependency-free (standard library only).
"""
from __future__ import annotations

import csv
import sys
from dataclasses import dataclass, field


@dataclass
class Stats:
    trades: int = 0
    wins: int = 0
    losses: int = 0
    gross_profit: float = 0.0
    gross_loss: float = 0.0            # stored as a negative number
    net: float = 0.0
    largest_win: float = 0.0
    largest_loss: float = 0.0
    max_drawdown: float = 0.0          # worst peak-to-trough of the equity curve
    equity_curve: list[float] = field(default_factory=list)

    @property
    def win_rate(self) -> float:
        return 100.0 * self.wins / self.trades if self.trades else 0.0

    @property
    def profit_factor(self) -> float:
        return self.gross_profit / abs(self.gross_loss) if self.gross_loss else float("inf")

    @property
    def avg_win(self) -> float:
        return self.gross_profit / self.wins if self.wins else 0.0

    @property
    def avg_loss(self) -> float:
        return self.gross_loss / self.losses if self.losses else 0.0

    @property
    def expectancy(self) -> float:
        """Average P/L per trade -- the single most honest number."""
        return self.net / self.trades if self.trades else 0.0


def _trade_pnl(row: dict) -> float:
    def num(key: str) -> float:
        try:
            return float(row.get(key, 0) or 0)
        except ValueError:
            return 0.0
    # Net of costs: broker profit already excludes swap/commission columns.
    return num("profit") + num("swap") + num("commission")


def stats_from_pnls(pnls: list[float]) -> Stats:
    """Build a Stats from a sequence of per-trade P/L values. Shared by the
    journal analyzer and the backtester so both report identically."""
    st = Stats()
    equity = 0.0
    peak = 0.0
    for pnl in pnls:
        st.trades += 1
        st.net += pnl
        if pnl >= 0:
            st.wins += 1
            st.gross_profit += pnl
            st.largest_win = max(st.largest_win, pnl)
        else:
            st.losses += 1
            st.gross_loss += pnl
            st.largest_loss = min(st.largest_loss, pnl)

        equity += pnl
        st.equity_curve.append(equity)
        peak = max(peak, equity)
        st.max_drawdown = min(st.max_drawdown, equity - peak)
    return st


def analyze(path: str) -> Stats:
    with open(path, newline="", encoding="utf-8") as fh:
        pnls = [_trade_pnl(row) for row in csv.DictReader(fh)]
    return stats_from_pnls(pnls)


def _fmt(x: float) -> str:
    return f"{x:,.2f}"


def report(st: Stats) -> str:
    pf = st.profit_factor
    pf_txt = "inf" if pf == float("inf") else f"{pf:.2f}"
    verdict = _verdict(st)
    lines = [
        "=" * 44,
        "  SpirCore-AutoTrader -- Performance Report",
        "=" * 44,
        f"  Trades            : {st.trades}",
        f"  Wins / Losses     : {st.wins} / {st.losses}",
        f"  Win rate          : {st.win_rate:.1f}%",
        f"  Net profit        : {_fmt(st.net)}",
        f"  Gross profit/loss : {_fmt(st.gross_profit)} / {_fmt(st.gross_loss)}",
        f"  Profit factor     : {pf_txt}",
        f"  Expectancy/trade  : {_fmt(st.expectancy)}",
        f"  Avg win / avg loss: {_fmt(st.avg_win)} / {_fmt(st.avg_loss)}",
        f"  Largest win/loss  : {_fmt(st.largest_win)} / {_fmt(st.largest_loss)}",
        f"  Max drawdown      : {_fmt(st.max_drawdown)}",
        "-" * 44,
        f"  Read:  {verdict}",
        "=" * 44,
    ]
    return "\n".join(lines)


def _verdict(st: Stats) -> str:
    if st.trades < 30:
        return "too few trades to judge (aim for 100+)."
    pf = st.profit_factor
    if st.net <= 0 or pf < 1.0:
        return "losing system -- do NOT trade live."
    if pf < 1.3:
        return "marginal edge; costs/slippage may erase it."
    return "positive on this sample -- still forward-test on Demo."


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "spircore_journal.csv"
    try:
        st = analyze(path)
    except FileNotFoundError:
        print(f"Journal not found: {path}")
        print("Run the EA (with InpWriteJournal=true) to generate it, then re-run.")
        return 1
    if st.trades == 0:
        print(f"No trades found in {path}.")
        return 1
    print(report(st))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
