#!/usr/bin/env python3
"""
SpirCore-AutoTrader :: Strategy backtester

Reimplements the three EA strategies (CEZLSMA, BBRSI, LRCUTB) in pure
Python and simulates them bar-by-bar over historical XAUUSD data, then
ranks strategy x dataset by profit factor. Use it to decide which
strategy/timeframe (if any) deserves forward-testing on Demo.

Data sources
  * CSV files: columns time,open,high,low,close (extra columns ignored).
    Each file is treated as one dataset (label = filename).
      python backtest.py data_M5.csv data_M15.csv
  * Live from MT5 (Windows, terminal running):
      python backtest.py --mt5 --symbol XAUUSD --timeframes M5,M15,H1 --bars 5000

Notes
  * P/L is measured in PRICE units (profit factor / win rate are unit-free);
    a per-trade spread cost is subtracted for realism.
  * One position at a time; entry at the signal bar's close; exit on SL/TP
    touched intrabar (SL assumed first when a bar straddles both).
  * This is an approximation, not the MT5 Strategy Tester. Treat a good
    result as "worth forward-testing", never as proof.

Dependency-free (standard library only).
"""
from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass

from analyze import Stats, report, stats_from_pnls


# ===========================================================================
#  Bar data
# ===========================================================================
@dataclass
class Bars:
    label: str
    time: list
    open: list
    high: list
    low: list
    close: list

    def __len__(self):
        return len(self.close)


def load_csv(path: str) -> Bars:
    t, o, h, l, c = [], [], [], [], []
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            t.append(row.get("time", ""))
            o.append(float(row["open"]))
            h.append(float(row["high"]))
            l.append(float(row["low"]))
            c.append(float(row["close"]))
    label = path.rsplit("/", 1)[-1]
    return Bars(label, t, o, h, l, c)


def load_mt5(symbol: str, tf_name: str, n: int) -> Bars:
    import MetaTrader5 as mt5  # optional dependency

    tf_map = {
        "M1": mt5.TIMEFRAME_M1, "M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1, "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1,
    }
    if tf_name not in tf_map:
        raise ValueError(f"unknown timeframe {tf_name}")
    if not mt5.initialize():
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")
    rates = mt5.copy_rates_from_pos(symbol, tf_map[tf_name], 0, n)
    mt5.shutdown()
    if rates is None or len(rates) == 0:
        raise RuntimeError("no rates returned from MT5")
    return Bars(
        f"{symbol}-{tf_name}",
        [r["time"] for r in rates],
        [r["open"] for r in rates],
        [r["high"] for r in rates],
        [r["low"] for r in rates],
        [r["close"] for r in rates],
    )


# ===========================================================================
#  Indicators (pure Python, chronological index 0..n-1)
# ===========================================================================
def lsma_endpoint(vals, i, length):
    """Linear-regression endpoint over the window ending at bar i."""
    if i - length + 1 < 0:
        return None
    sx = sy = sxx = sxy = 0.0
    for t in range(length):
        y = vals[i - length + 1 + t]
        sx += t
        sy += y
        sxx += t * t
        sxy += t * y
    denom = length * sxx - sx * sx
    if abs(denom) < 1e-12:
        return vals[i]
    slope = (length * sxy - sx * sy) / denom
    intercept = (sy - slope * sx) / length
    return intercept + slope * (length - 1)


def zlsma(closes, i, length):
    if i - 2 * (length - 1) < 0:
        return None
    l1 = [lsma_endpoint(closes, j, length) for j in range(i - length + 1, i + 1)]
    lsma2 = lsma_endpoint(l1, length - 1, length)
    return 2.0 * l1[-1] - lsma2


def rsi_wilder(closes, period):
    n = len(closes)
    out = [None] * n
    if n <= period:
        return out
    gains = losses = 0.0
    for i in range(1, period + 1):
        d = closes[i] - closes[i - 1]
        gains += max(d, 0.0)
        losses += max(-d, 0.0)
    avg_g = gains / period
    avg_l = losses / period
    out[period] = 100.0 - 100.0 / (1.0 + (avg_g / avg_l if avg_l else 1e9))
    for i in range(period + 1, n):
        d = closes[i] - closes[i - 1]
        avg_g = (avg_g * (period - 1) + max(d, 0.0)) / period
        avg_l = (avg_l * (period - 1) + max(-d, 0.0)) / period
        rs = avg_g / avg_l if avg_l else 1e9
        out[i] = 100.0 - 100.0 / (1.0 + rs)
    return out


def atr_wilder(highs, lows, closes, period):
    n = len(closes)
    out = [None] * n
    if n <= period:
        return out
    trs = []
    for i in range(1, n):
        tr = max(highs[i] - lows[i], abs(highs[i] - closes[i - 1]), abs(lows[i] - closes[i - 1]))
        trs.append(tr)
    first = sum(trs[:period]) / period
    out[period] = first
    prev = first
    for i in range(period + 1, n):
        prev = (prev * (period - 1) + trs[i - 1]) / period
        out[i] = prev
    return out


def bollinger(closes, i, length, dev):
    if i - length + 1 < 0:
        return None
    window = closes[i - length + 1:i + 1]
    mean = sum(window) / length
    var = sum((x - mean) ** 2 for x in window) / length
    sd = var ** 0.5
    return mean, mean + dev * sd, mean - dev * sd  # mid, upper, lower


def sma_series(vals, length):
    n = len(vals)
    out = [None] * n
    for i in range(length - 1, n):
        seg = vals[i - length + 1:i + 1]
        if any(v is None for v in seg):
            continue
        out[i] = sum(seg) / length
    return out


def ema_series(vals, period):
    n = len(vals)
    out = [None] * n
    if n == 0:
        return out
    k = 2.0 / (period + 1)
    out[0] = vals[0]
    for i in range(1, n):
        out[i] = vals[i] * k + out[i - 1] * (1 - k)
    return out


def macd_series(closes, fast, slow, signal):
    """Return (macd_main, macd_signal) series."""
    ef = ema_series(closes, fast)
    es = ema_series(closes, slow)
    main = [ef[i] - es[i] for i in range(len(closes))]
    sig = ema_series(main, signal)
    return main, sig


def stochastic_main(highs, lows, closes, kperiod, slowing):
    """Slowed %K (the 'main' line), aligned to bars."""
    n = len(closes)
    raw = [None] * n
    for i in range(kperiod - 1, n):
        hh = max(highs[i - kperiod + 1:i + 1])
        ll = min(lows[i - kperiod + 1:i + 1])
        rng = hh - ll
        raw[i] = 50.0 if rng == 0 else 100.0 * (closes[i] - ll) / rng
    # slowing = SMA of raw %K
    out = [None] * n
    for i in range(n):
        seg = raw[max(0, i - slowing + 1):i + 1]
        if any(v is None for v in seg) or len(seg) < slowing:
            continue
        out[i] = sum(seg) / slowing
    return out


def nw_estimate(closes, i, window, band, mult):
    """Nadaraya-Watson value + envelope half-width (mean abs dev * mult) at bar i."""
    if i - window + 1 < 0:
        return None
    sw = swc = 0.0
    for k in range(window):
        w = 2.718281828 ** (-(k * k) / (2.0 * band * band))
        sw += w
        swc += w * closes[i - k]
    if sw <= 0:
        return None
    nw = swc / sw
    mad = sum(abs(closes[i - k] - nw) for k in range(window)) / window
    return nw, mad * mult


# ===========================================================================
#  Strategy signal precomputation -> list of (dir, sl_price) per bar or None
# ===========================================================================
@dataclass
class Params:
    point: float = 0.01
    spread_pts: int = 20
    tp_coef: float = 1.5
    sl_dev_pts: int = 50
    # CEZLSMA
    ce_atr: int = 1
    ce_mult: float = 0.75
    zl_len: int = 50
    # BBRSI
    bb_len: int = 500
    bb_dev: float = 2.0
    rsi_len: int = 7
    # LRCUTB
    lrc_len: int = 11
    lrc_sma: int = 7
    utb_atr: int = 1
    utb_coef: float = 2.0
    swing_look: int = 10
    # 2MACDSTO
    sto_level: int = 30
    # NWE
    nwe_window: int = 100
    nwe_band: float = 8.0
    nwe_mult: float = 3.0


def chandelier(bars: Bars, p: Params):
    n = len(bars)
    atr = atr_wilder(bars.high, bars.low, bars.close, p.ce_atr)
    long_stop = [0.0] * n
    short_stop = [0.0] * n
    direction = [0] * n
    for i in range(1, n):
        if atr[i] is None:
            continue
        long_basic = bars.high[i] - p.ce_mult * atr[i]
        short_basic = bars.low[i] + p.ce_mult * atr[i]
        long_stop[i] = max(long_basic, long_stop[i - 1]) if bars.close[i - 1] > long_stop[i - 1] else long_basic
        short_stop[i] = min(short_basic, short_stop[i - 1]) if bars.close[i - 1] < short_stop[i - 1] else short_basic
        if bars.close[i] > short_stop[i - 1]:
            direction[i] = 1
        elif bars.close[i] < long_stop[i - 1]:
            direction[i] = -1
        else:
            direction[i] = direction[i - 1]
    return direction, long_stop, short_stop


def utbot(bars: Bars, p: Params):
    n = len(bars)
    atr = atr_wilder(bars.high, bars.low, bars.close, p.utb_atr)
    stop = [0.0] * n
    buy = [False] * n
    sell = [False] * n
    for i in range(1, n):
        if atr[i] is None:
            continue
        nloss = p.utb_coef * atr[i]
        prev = stop[i - 1]
        c, cp = bars.close[i], bars.close[i - 1]
        if c > prev and cp > prev:
            stop[i] = max(prev, c - nloss)
        elif c < prev and cp < prev:
            stop[i] = min(prev, c + nloss)
        elif c > prev:
            stop[i] = c - nloss
        else:
            stop[i] = c + nloss
        if c > stop[i] and cp <= prev:
            buy[i] = True
        if c < stop[i] and cp >= prev:
            sell[i] = True
    return buy, sell


def signals_cezlsma(bars: Bars, p: Params):
    n = len(bars)
    direction, long_stop, short_stop = chandelier(bars, p)
    dev = p.sl_dev_pts * p.point
    out = [None] * n
    for i in range(n):
        zl = zlsma(bars.close, i, p.zl_len)
        if zl is None:
            continue
        hac = (bars.open[i] + bars.high[i] + bars.low[i] + bars.close[i]) / 4.0
        if direction[i] == 1 and hac > zl:
            out[i] = (1, long_stop[i] - dev)
        elif direction[i] == -1 and hac < zl:
            out[i] = (-1, short_stop[i] + dev)
    return out


def signals_bbrsi(bars: Bars, p: Params):
    n = len(bars)
    rsi = rsi_wilder(bars.close, p.rsi_len)
    dev = p.sl_dev_pts * p.point
    out = [None] * n
    for i in range(1, n):
        b_i = bollinger(bars.close, i, p.bb_len, p.bb_dev)
        b_p = bollinger(bars.close, i - 1, p.bb_len, p.bb_dev)
        if b_i is None or b_p is None or rsi[i] is None or rsi[i - 1] is None:
            continue
        mb, ub, lb = b_i
        _, ub_p, lb_p = b_p
        c, cp = bars.close[i], bars.close[i - 1]
        if rsi[i - 1] < 30 and cp < lb_p and rsi[i] > 30 and c > lb and rsi[i] < 50 and c < mb:
            out[i] = (1, lb - dev)
        elif rsi[i - 1] > 70 and cp > ub_p and rsi[i] < 70 and c < ub and rsi[i] > 50 and c > mb:
            out[i] = (-1, ub + dev)
    return out


def signals_lrcutb(bars: Bars, p: Params):
    n = len(bars)
    buy, sell = utbot(bars, p)
    dev = p.sl_dev_pts * p.point
    lrc_c = [lsma_endpoint(bars.close, i, p.lrc_len) for i in range(n)]
    lrc_o = [lsma_endpoint(bars.open, i, p.lrc_len) for i in range(n)]
    lrc_s = sma_series(lrc_c, p.lrc_sma)
    out = [None] * n
    for i in range(n):
        if lrc_c[i] is None or lrc_o[i] is None or lrc_s[i] is None:
            continue
        utb_bull = any(buy[j] for j in (i, i - 1, i - 2) if j >= 0)
        utb_bear = any(sell[j] for j in (i, i - 1, i - 2) if j >= 0)
        if lrc_c[i] > lrc_o[i] and lrc_c[i] > lrc_s[i] and utb_bull:
            lo = min(bars.low[max(0, i - p.swing_look + 1):i + 1])
            out[i] = (1, lo - dev)
        elif lrc_c[i] < lrc_o[i] and lrc_c[i] < lrc_s[i] and utb_bear:
            hi = max(bars.high[max(0, i - p.swing_look + 1):i + 1])
            out[i] = (-1, hi + dev)
    return out


def _swing_sl(bars: Bars, i: int, is_buy: bool, look: int, dev: float):
    if is_buy:
        return min(bars.low[max(0, i - look + 1):i + 1]) - dev
    return max(bars.high[max(0, i - look + 1):i + 1]) + dev


def signals_2macdsto(bars: Bars, p: Params):
    n = len(bars)
    mf_main, mf_sig = macd_series(bars.close, 12, 26, 9)
    ms_main, ms_sig = macd_series(bars.close, 24, 52, 9)
    sto = stochastic_main(bars.high, bars.low, bars.close, 14, 3)
    dev = p.sl_dev_pts * p.point
    out = [None] * n
    for i in range(1, n):
        if sto[i] is None:
            continue
        bullish = mf_main[i] > mf_sig[i] and ms_main[i] > ms_sig[i]
        bearish = mf_main[i] < mf_sig[i] and ms_main[i] < ms_sig[i]
        if bullish and sto[i] < p.sto_level:
            out[i] = (1, _swing_sl(bars, i, True, p.swing_look, dev))
        elif bearish and sto[i] > (100 - p.sto_level):
            out[i] = (-1, _swing_sl(bars, i, False, p.swing_look, dev))
    return out


def signals_nwe(bars: Bars, p: Params):
    n = len(bars)
    rsi = rsi_wilder(bars.close, p.rsi_len)
    dev = p.sl_dev_pts * p.point
    out = [None] * n
    for i in range(2, n):
        est = nw_estimate(bars.close, i, p.nwe_window, p.nwe_band, p.nwe_mult)
        if est is None or rsi[i] is None:
            continue
        nw, mae = est
        upper, lower = nw + mae, nw - mae
        c, cp = bars.close[i], bars.close[i - 1]
        if cp < lower and c > cp and rsi[i] < 40:
            out[i] = (1, lower - dev)
        elif cp > upper and c < cp and rsi[i] > 60:
            out[i] = (-1, upper + dev)
    return out


STRATEGIES = {
    "CEZLSMA": signals_cezlsma,
    "BBRSI": signals_bbrsi,
    "LRCUTB": signals_lrcutb,
    "2MACDSTO": signals_2macdsto,
    "NWE": signals_nwe,
}


# ===========================================================================
#  Simulation engine
# ===========================================================================
def simulate(bars: Bars, signals, p: Params) -> list:
    """Return the list of per-trade P/L (price units, net of spread)."""
    pnls = []
    spread_cost = p.spread_pts * p.point
    pos = None  # (dir, entry, sl, tp)
    n = len(bars)
    for i in range(n):
        if pos is not None:
            d, entry, sl, tp = pos
            exit_px = None
            if d == 1:
                if bars.low[i] <= sl:
                    exit_px = sl
                elif bars.high[i] >= tp:
                    exit_px = tp
            else:
                if bars.high[i] >= sl:
                    exit_px = sl
                elif bars.low[i] <= tp:
                    exit_px = tp
            if exit_px is not None:
                pnl = (exit_px - entry) if d == 1 else (entry - exit_px)
                pnls.append(pnl - spread_cost)
                pos = None

        if pos is None and signals[i] is not None:
            d, sl = signals[i]
            if sl <= 0:
                continue
            entry = bars.close[i]
            risk = abs(entry - sl)
            if risk <= 0:
                continue
            tp = entry + p.tp_coef * risk if d == 1 else entry - p.tp_coef * risk
            pos = (d, entry, sl, tp)

    if pos is not None:  # mark-to-market the last open trade
        d, entry, sl, tp = pos
        last = bars.close[-1]
        pnls.append(((last - entry) if d == 1 else (entry - last)) - spread_cost)
    return pnls


@dataclass
class Row:
    dataset: str
    strategy: str
    st: Stats


def run(datasets: list, p: Params) -> list:
    rows = []
    for bars in datasets:
        for name, fn in STRATEGIES.items():
            pnls = simulate(bars, fn(bars, p), p)
            rows.append(Row(bars.label, name, stats_from_pnls(pnls)))
    return rows


def _pf(st: Stats) -> float:
    return st.profit_factor if st.gross_loss else 0.0  # inf -> treat as 0 for ranking realism


def print_ranking(rows: list):
    rows_sorted = sorted(
        rows,
        key=lambda r: (r.st.profit_factor if r.st.trades >= 10 else -1, r.st.net),
        reverse=True,
    )
    print("=" * 72)
    print(f"{'Dataset':<18}{'Strategy':<10}{'Trades':>7}{'Win%':>7}{'PF':>7}{'Net':>10}{'MaxDD':>10}")
    print("-" * 72)
    for r in rows_sorted:
        s = r.st
        pf = "inf" if s.profit_factor == float("inf") else f"{s.profit_factor:.2f}"
        print(f"{r.dataset:<18}{r.strategy:<10}{s.trades:>7}{s.win_rate:>6.1f}%"
              f"{pf:>7}{s.net:>10.2f}{s.max_drawdown:>10.2f}")
    print("=" * 72)
    print("PF>=1.3 with 100+ trades is a candidate to forward-test. Everything")
    print("else is noise. A backtest is a filter, not a promise.")


def main() -> int:
    ap = argparse.ArgumentParser(description="SpirCore strategy backtester")
    ap.add_argument("csv", nargs="*", help="CSV file(s): time,open,high,low,close")
    ap.add_argument("--mt5", action="store_true", help="pull data from a running MT5 terminal")
    ap.add_argument("--symbol", default="XAUUSD")
    ap.add_argument("--timeframes", default="M5,M15,H1")
    ap.add_argument("--bars", type=int, default=5000)
    ap.add_argument("--point", type=float, default=0.01)
    ap.add_argument("--spread-pts", type=int, default=20)
    ap.add_argument("--tp-coef", type=float, default=1.5)
    ap.add_argument("--sto-level", type=int, default=30, help="2MACDSTO Stochastic threshold")
    ap.add_argument("--nwe-window", type=int, default=100)
    ap.add_argument("--nwe-band", type=float, default=8.0)
    ap.add_argument("--nwe-mult", type=float, default=3.0)
    ap.add_argument("--detail", action="store_true", help="print a full report per row")
    args = ap.parse_args()

    p = Params(point=args.point, spread_pts=args.spread_pts, tp_coef=args.tp_coef,
               sto_level=args.sto_level, nwe_window=args.nwe_window,
               nwe_band=args.nwe_band, nwe_mult=args.nwe_mult)

    datasets = []
    if args.mt5:
        for tf in args.timeframes.split(","):
            datasets.append(load_mt5(args.symbol, tf.strip(), args.bars))
    for path in args.csv:
        datasets.append(load_csv(path))

    if not datasets:
        ap.print_help()
        return 1

    rows = run(datasets, p)
    print_ranking(rows)
    if args.detail:
        for r in rows:
            print(f"\n### {r.dataset} / {r.strategy}")
            print(report(r.st))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
