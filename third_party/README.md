# third_party/

Vendored, unmodified third-party code. Each subfolder keeps its own license.
Nothing here is imported by the SpirCore bridge, EA, SaaS, or extension, and
CI does not compile or test it — it is reference material only.

## day-trader-skill/
- **Source:** https://github.com/Jakeschincariol/day-trader-skill (MIT, see its `LICENSE`).
- **What it is:** a package of 11 **Claude Skills** (SKILL.md + stdlib-Python tools)
  for **US-equities day trading** — scanner, news, entry/exit, Time Machine
  simulation, risk, budget, Alpaca broker routing, alerts, earnings analyst,
  and a congressional-trades tracker.

### ⚠️ Market/platform mismatch — read before using
This package is built for **US stocks via Alpaca**, using **Yahoo Finance /
SEC EDGAR / Nasdaq** data. SpirCore trades **gold (XAUUSD) on MetaTrader 5**.
**The stock/Alpaca/SEC tools do NOT work for XAUUSD or MT5.** It is kept here
as reference, not as a component of the gold bot.

### How to actually use it (on YOUR machine, not this repo)
It is a Claude-Code skill package — install it where you run Claude Code, e.g.:
```
/plugin marketplace add Jakeschincariol/day-trader-skill
/plugin install day-trader-skill@day-trader-skill
```
or copy the `trader-*` folders into your `~/.claude/skills/`.

**Safety (keep these defaults):** paper trading only (`"paper": true`); do not
connect a live brokerage or place real orders; set the broker tool to
"Needs approval"; store any broker keys in env vars, never in chat; ask before
any payment. Most day traders lose money — this is not financial advice.

### What SpirCore adapted from it
The one genuinely transferable idea — the **Time Machine** (a pre-trade
Monte-Carlo simulation over the instrument's own recent bars, plus a
historical replay) — has been **re-implemented for XAUUSD/MT5** in
`bridge/timemachine.py` (standard library only, works on MT5 bars). That
adaptation is **a simulation of probabilities, not a prediction or a profit
guarantee.**
