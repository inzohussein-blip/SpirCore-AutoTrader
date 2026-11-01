#!/usr/bin/env python3
"""XAUUSD Time Machine -- pre-trade Monte-Carlo simulation. Standard library only.

Adapted for gold (XAUUSD) on MT5 from the US-equities "trader-timemachine"
skill (github.com/Jakeschincariol/day-trader-skill, MIT). Same spirit, same
conservative stop-before-target rule; the data source is MT5 bars instead of
Yahoo, and gold's ~24h trading means we bootstrap per-bar OHLC ratios from the
recent pool rather than slotting a fixed NYSE session.

Replays a planned trade before you risk a dollar:
  1. simulate()  -- N forward paths from your entry, each bar sampled (in short
     blocks, to keep autocorrelation) from the symbol's own recent bars and
     scaled to the running price. The STOP is checked before the TARGET on
     every bar, so a bar that touches both counts as the stop (the safe call).
     Outcomes: "target" / "stop" (whichever first) or "open" at the horizon.
  2. replay()    -- the same SL/TP distances applied at each recent bar as a
     hypothetical entry, walked forward over the ACTUAL later bars. Deterministic.

Same bars, same --seed -> same numbers on any machine. A simulation built from
recent bars is NOT a prediction: news, rollovers and gaps can do what the last
bars never did. These are probabilities, not a profit guarantee.

CLI:
    python3 timemachine.py --bars tests/sample_bars.csv --dir buy \\
        --entry 3350 --sl 3344 --tp 3362 --sims 10000 --seed 19 --json
    python3 timemachine.py --dir buy --sl 3344 --tp 3362   # entry+bars from MT5
"""
from __future__ import annotations

import argparse
import csv
import json
import random
from typing import Optional

MIN_POOL = 20          # refuse a verdict on too little data
DEFAULT_SIMS = 10000
DEFAULT_HORIZON = 48   # bars to let the trade run before calling it "open"
DEFAULT_BLOCK = 6      # consecutive bars drawn per bootstrap block
DEFAULT_SEED = 19


# --------------------------------------------------------------------------
# Pure helpers (no MT5, no I/O) -- these are what the tests exercise.
# --------------------------------------------------------------------------
def _ratios(bars: list) -> list:
    """Per-bar (open, high, low, close) ratios to the previous bar's close."""
    pool = []
    for i in range(1, len(bars)):
        prev_c = float(bars[i - 1]["close"])
        if prev_c <= 0:
            continue
        b = bars[i]
        pool.append((float(b["open"]) / prev_c, float(b["high"]) / prev_c,
                     float(b["low"]) / prev_c, float(b["close"]) / prev_c))
    return pool


def _hit(direction: str, sl: float, tp: float,
         high: float, low: float) -> Optional[str]:
    """Outcome for one candle. Stop is tested before target (conservative)."""
    if direction == "buy":
        if low <= sl:
            return "stop"
        if high >= tp:
            return "target"
    else:  # sell
        if high >= sl:
            return "stop"
        if low <= tp:
            return "target"
    return None


def _validate(entry: float, sl: float, tp: float, direction: str) -> Optional[str]:
    if direction not in ("buy", "sell"):
        return "direction must be buy or sell"
    if direction == "buy" and not (sl < entry < tp):
        return "for a buy, need sl < entry < tp"
    if direction == "sell" and not (tp < entry < sl):
        return "for a sell, need tp < entry < sl"
    return None


def _pct(sorted_vals: list, q: float) -> float:
    if not sorted_vals:
        return 0.0
    i = min(len(sorted_vals) - 1, max(0, int(q * len(sorted_vals))))
    return sorted_vals[i]


def _verdict(p_target: float, p_stop: float, rmult: float, p_open: float) -> str:
    decided = p_target + p_stop
    if decided <= 0:
        return "No simulated path hit the stop or target in the horizon."
    share = p_target / decided
    breakeven = 1.0 / (1.0 + rmult)
    gap = (share - breakeven) * 100.0
    toward = "target" if gap >= 0 else "stop"
    mag = abs(gap)
    if mag < 5:
        base = "Close to a coin flip" if abs(rmult - 1.0) < 1e-6 else "Close to break-even"
    elif mag < 15:
        base = f"Leans toward the {toward}"
    else:
        base = f"Strongly toward the {toward}"
    note = ""
    if p_open > 0.40:
        note = f" ({p_open*100:.0f}% still open at the horizon -- exit timing decides those)"
    return base + note


# --------------------------------------------------------------------------
# Monte-Carlo simulation + historical replay
# --------------------------------------------------------------------------
def simulate(bars: list, entry: float, sl: float, tp: float, direction: str,
             horizon: int = DEFAULT_HORIZON, n_sims: int = DEFAULT_SIMS,
             seed: int = DEFAULT_SEED, block: int = DEFAULT_BLOCK) -> dict:
    """N bootstrapped forward paths. Returns probabilities + an R summary."""
    direction = direction.lower()
    err = _validate(entry, sl, tp, direction)
    if err:
        return {"ok": False, "detail": err}
    pool = _ratios(bars)
    if len(pool) < MIN_POOL:
        return {"ok": False, "detail": f"need >= {MIN_POOL} bars, have {len(pool)}"}

    risk = abs(entry - sl)
    reward = abs(tp - entry)
    rmult = reward / risk if risk > 0 else 0.0
    sign = 1.0 if direction == "buy" else -1.0

    rng = random.Random(seed)
    n_pool = len(pool)
    counts = {"target": 0, "stop": 0, "open": 0}
    r_values = []
    finals = []

    for _ in range(n_sims):
        price = entry
        idx, remaining = 0, 0
        outcome, r = None, 0.0
        for _step in range(horizon):
            if remaining <= 0:
                idx = rng.randrange(n_pool)
                remaining = block
            ro, rh, rl, rc = pool[idx]
            idx = (idx + 1) % n_pool
            remaining -= 1
            high, low = price * rh, price * rl
            outcome = _hit(direction, sl, tp, high, low)
            if outcome == "target":
                r = rmult
                break
            if outcome == "stop":
                r = -1.0
                break
            price = price * rc  # carry the running price forward
        if outcome is None:
            outcome = "open"
            r = sign * (price - entry) / risk if risk > 0 else 0.0
            finals.append(price)
        counts[outcome] += 1
        r_values.append(r)

    finals.sort()
    n = float(n_sims)
    p_target, p_stop, p_open = counts["target"]/n, counts["stop"]/n, counts["open"]/n
    return {
        "ok": True,
        "direction": direction, "entry": entry, "sl": sl, "tp": tp,
        "risk": round(risk, 5), "reward": round(reward, 5), "rr": round(rmult, 3),
        "sims": n_sims, "horizon": horizon, "seed": seed, "pool": n_pool,
        "p_target": round(p_target, 4),
        "p_stop": round(p_stop, 4),
        "p_open": round(p_open, 4),
        "avg_r": round(sum(r_values) / n, 3),
        "median_open_price": round(_pct(finals, 0.5), 5) if finals else None,
        "p5_open_price": round(_pct(finals, 0.05), 5) if finals else None,
        "p95_open_price": round(_pct(finals, 0.95), 5) if finals else None,
        "verdict": _verdict(p_target, p_stop, rmult, p_open),
    }


def replay(bars: list, entry: float, sl: float, tp: float, direction: str,
           horizon: int = DEFAULT_HORIZON) -> dict:
    """Deterministic: apply the same risk/reward distances at each recent bar
    as a hypothetical entry, walked forward over the ACTUAL later bars."""
    direction = direction.lower()
    if _validate(entry, sl, tp, direction):
        return {"ok": False, "detail": "invalid plan"}
    risk_px = abs(entry - sl)
    reward_px = abs(tp - entry)
    counts = {"target": 0, "stop": 0, "open": 0}
    trials = 0
    last_start = len(bars) - 2  # need at least one forward bar
    for i in range(last_start):
        p = float(bars[i]["close"])
        if direction == "buy":
            h_sl, h_tp = p - risk_px, p + reward_px
        else:
            h_sl, h_tp = p + risk_px, p - reward_px
        outcome = None
        for j in range(i + 1, min(i + 1 + horizon, len(bars))):
            b = bars[j]
            outcome = _hit(direction, h_sl, h_tp, float(b["high"]), float(b["low"]))
            if outcome:
                break
        counts[outcome or "open"] += 1
        trials += 1
    if trials == 0:
        return {"ok": False, "detail": "not enough bars to replay"}
    decided = counts["target"] + counts["stop"]
    return {
        "ok": True, "trials": trials,
        "target": counts["target"], "stop": counts["stop"], "open": counts["open"],
        "hit_rate_target": round(counts["target"] / decided, 4) if decided else None,
    }


def run(bars: list, entry: float, sl: float, tp: float, direction: str,
        horizon: int = DEFAULT_HORIZON, n_sims: int = DEFAULT_SIMS,
        seed: int = DEFAULT_SEED, block: int = DEFAULT_BLOCK) -> dict:
    """Full report: simulation + historical replay + the standing caveat."""
    sim = simulate(bars, entry, sl, tp, direction, horizon, n_sims, seed, block)
    if not sim.get("ok"):
        return sim
    return {**sim, "history": replay(bars, entry, sl, tp, direction, horizon),
            "disclaimer": "Simulation of probabilities from recent bars -- "
                          "not a prediction and not a profit guarantee."}


# --------------------------------------------------------------------------
# I/O: CSV fixture + live MT5
# --------------------------------------------------------------------------
def load_bars_csv(path: str) -> list:
    with open(path, newline="", encoding="utf-8") as fh:
        return [{"open": r["open"], "high": r["high"],
                 "low": r["low"], "close": r["close"]} for r in csv.DictReader(fh)]


def from_mt5(sl: float, tp: float, direction: str, entry: Optional[float] = None,
             count: int = 600, horizon: int = DEFAULT_HORIZON,
             n_sims: int = DEFAULT_SIMS, seed: int = DEFAULT_SEED,
             block: int = DEFAULT_BLOCK) -> dict:
    """Pull recent bars + current price from MT5, then run(). MT5 is imported
    lazily so this module stays importable (and testable) off-Windows."""
    import mt5_client  # noqa: E402  (hard-imports MetaTrader5)
    bars = mt5_client.copy_bars(count)
    if not bars:
        return {"ok": False, "detail": "no bars from MT5 (terminal connected?)"}
    if entry is None:
        entry = mt5_client.current_price()
        if not entry:
            return {"ok": False, "detail": "no current price from MT5"}
    return run(bars, entry, sl, tp, direction, horizon, n_sims, seed, block)


def _main() -> int:
    ap = argparse.ArgumentParser(description="XAUUSD Time Machine (simulation, not advice)")
    ap.add_argument("--bars", help="OHLC CSV (time,open,high,low,close); omit to use MT5")
    ap.add_argument("--dir", required=True, choices=["buy", "sell"])
    ap.add_argument("--entry", type=float, help="entry price (default: last close / MT5 price)")
    ap.add_argument("--sl", type=float, required=True)
    ap.add_argument("--tp", type=float, required=True)
    ap.add_argument("--sims", type=int, default=DEFAULT_SIMS)
    ap.add_argument("--horizon", type=int, default=DEFAULT_HORIZON)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    ap.add_argument("--block", type=int, default=DEFAULT_BLOCK)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    if a.bars:
        bars = load_bars_csv(a.bars)
        entry = a.entry if a.entry is not None else float(bars[-1]["close"])
        res = run(bars, entry, a.sl, a.tp, a.dir, a.horizon, a.sims, a.seed, a.block)
    else:
        res = from_mt5(a.sl, a.tp, a.dir, a.entry, 600, a.horizon, a.sims, a.seed, a.block)

    if a.json:
        print(json.dumps(res, indent=2))
        return 0 if res.get("ok") else 1
    if not res.get("ok"):
        print("error:", res.get("detail"))
        return 1
    print(f"XAUUSD Time Machine  {res['direction'].upper()}  entry {res['entry']} "
          f"SL {res['sl']} TP {res['tp']}  (R:R {res['rr']})")
    print(f"  sims {res['sims']} | pool {res['pool']} bars | horizon {res['horizon']}")
    print(f"  target first : {res['p_target']*100:5.1f}%")
    print(f"  stop first   : {res['p_stop']*100:5.1f}%")
    print(f"  still open    : {res['p_open']*100:5.1f}%   avg R {res['avg_r']}")
    h = res.get("history") or {}
    if h.get("ok"):
        hr = h.get("hit_rate_target")
        print(f"  history      : {h['target']} target / {h['stop']} stop / {h['open']} open "
              f"({'' if hr is None else f'{hr*100:.0f}% target'})")
    print(f"  verdict      : {res['verdict']}")
    print(f"  {res['disclaimer']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
