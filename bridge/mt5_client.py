"""
SpirCore-AutoTrader :: Phase 2 - Local Python Bridge
MetaTrader 5 connector.

Mirrors the EA's execution discipline on the Python side:
  * strict spread filter (Market-Maker / news protection)
  * ECN/STP-compliant open: market order WITHOUT SL/TP, then an
    immediate order_send(TRADE_ACTION_SLTP) to attach the brackets.

All functions are thread-safe-ish for our use: the FastAPI handlers are
serialized through a single asyncio loop and MT5 calls are quick, but we
still guard the terminal with a lock to avoid interleaved order_send.
"""
from __future__ import annotations

import threading
import time
from datetime import datetime
from typing import Optional

import MetaTrader5 as mt5

from config import settings

_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------
def connect() -> None:
    """Initialize the terminal connection. Raises RuntimeError on failure."""
    kwargs = {}
    if settings.mt5_path:
        kwargs["path"] = settings.mt5_path
    if settings.mt5_login:
        kwargs.update(
            login=settings.mt5_login,
            password=settings.mt5_password,
            server=settings.mt5_server,
        )

    if not mt5.initialize(**kwargs):
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")

    if not mt5.symbol_select(settings.symbol, True):
        raise RuntimeError(f"Could not select symbol {settings.symbol}")


def shutdown() -> None:
    mt5.shutdown()


def terminal_status() -> dict:
    info = mt5.terminal_info()
    acc = mt5.account_info()
    return {
        "connected": bool(info.connected) if info else False,
        "trade_allowed": bool(info.trade_allowed) if info else False,
        "account": acc.login if acc else None,
        "balance": acc.balance if acc else None,
        "equity": acc.equity if acc else None,
        "server": acc.server if acc else None,
    }


# ---------------------------------------------------------------------------
# Market data helpers
# ---------------------------------------------------------------------------
def _sym(symbol: Optional[str]) -> str:
    return symbol or settings.symbol


def spread_points(symbol: Optional[str] = None) -> int:
    """Current spread in points (computed from ask-bid to stay broker-agnostic)."""
    s = _sym(symbol)
    info = mt5.symbol_info(s)
    tick = mt5.symbol_info_tick(s)
    if info is None or tick is None or info.point <= 0:
        return 10**9  # force a block if we cannot read the market
    return int(round((tick.ask - tick.bid) / info.point))


def spread_ok(symbol: Optional[str] = None) -> bool:
    sp = spread_points(symbol)
    if sp > settings.max_spread_pts:
        print(f"[spread] BLOCK: {sp} > max {settings.max_spread_pts}")
        return False
    return True


def count_own_positions(symbol: Optional[str] = None) -> int:
    s = _sym(symbol)
    positions = mt5.positions_get(symbol=s) or []
    return sum(1 for p in positions if p.magic == settings.magic)


# ---------------------------------------------------------------------------
# Risk guard (mirrors the EA: daily loss limit + trades/day cap)
# ---------------------------------------------------------------------------
def _start_of_day() -> datetime:
    now = datetime.now()
    return datetime(now.year, now.month, now.day)


def daily_pnl(symbol: Optional[str] = None) -> float:
    """Today's realized (closed deals) + floating P/L for this EA's magic."""
    s = _sym(symbol)
    realized = 0.0
    deals = mt5.history_deals_get(_start_of_day(), datetime.now()) or []
    for d in deals:
        if d.magic == settings.magic and d.symbol == s:
            realized += d.profit + d.swap + d.commission
    floating = 0.0
    for p in mt5.positions_get(symbol=s) or []:
        if p.magic == settings.magic:
            floating += p.profit + p.swap
    return realized + floating


def trades_today(symbol: Optional[str] = None) -> int:
    s = _sym(symbol)
    deals = mt5.history_deals_get(_start_of_day(), datetime.now()) or []
    return sum(
        1 for d in deals
        if d.magic == settings.magic and d.symbol == s and d.entry == mt5.DEAL_ENTRY_IN
    )


def risk_guard(symbol: Optional[str] = None) -> Optional[str]:
    """Return a block reason if a hard risk limit is hit, else None."""
    s = _sym(symbol)
    if settings.max_trades_per_day > 0 and trades_today(s) >= settings.max_trades_per_day:
        return "max trades/day reached"
    if settings.max_daily_loss_pct > 0:
        acc = mt5.account_info()
        if acc:
            max_loss = acc.balance * settings.max_daily_loss_pct / 100.0
            pnl = daily_pnl(s)
            if pnl <= -max_loss:
                return f"daily loss limit hit (P/L {pnl:.2f} <= -{max_loss:.2f})"
    return None


# ---------------------------------------------------------------------------
# Execution (ECN discipline)
# ---------------------------------------------------------------------------
def _filling_mode(symbol: str) -> int:
    """Pick a filling mode the symbol actually supports."""
    info = mt5.symbol_info(symbol)
    modes = info.filling_mode if info else 0
    if modes & mt5.SYMBOL_FILLING_FOK:
        return mt5.ORDER_FILLING_FOK
    if modes & mt5.SYMBOL_FILLING_IOC:
        return mt5.ORDER_FILLING_IOC
    return mt5.ORDER_FILLING_RETURN


def open_ecn(
    action: str,
    symbol: Optional[str] = None,
    lot: Optional[float] = None,
    sl_price: float = 0.0,
    tp_price: float = 0.0,
    comment: str = "spircore-bridge",
) -> dict:
    """
    Open a market position ECN-style and attach SL/TP afterwards.
    action: "buy" | "sell".
    """
    s = _sym(symbol)
    is_buy = action == "buy"

    with _lock:
        if not spread_ok(s):
            return {"ok": False, "detail": "spread filter blocked entry"}

        if count_own_positions(s) >= settings.max_positions:
            return {"ok": False, "detail": "max positions reached"}

        blocked = risk_guard(s)
        if blocked:
            print(f"[risk] BLOCK: {blocked}")
            return {"ok": False, "detail": f"risk guard: {blocked}"}

        info = mt5.symbol_info(s)
        tick = mt5.symbol_info_tick(s)
        if info is None or tick is None:
            return {"ok": False, "detail": "no market data"}

        volume = _normalize_lot(s, lot if lot else settings.default_lot)
        price = tick.ask if is_buy else tick.bid

        # ----- STEP 1: bare market order (no SL/TP) -----------------------
        req = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": s,
            "volume": volume,
            "type": mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL,
            "price": price,
            "deviation": settings.deviation_pts,
            "magic": settings.magic,
            "comment": comment,
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": _filling_mode(s),
        }
        res = mt5.order_send(req)
        if res is None or res.retcode != mt5.TRADE_RETCODE_DONE:
            return {
                "ok": False,
                "detail": f"open failed retcode={getattr(res, 'retcode', None)} "
                f"({getattr(res, 'comment', mt5.last_error())})",
            }

        fill_price = res.price
        ticket = _find_position_ticket(s)

        # ----- STEP 2: attach SL/TP (ECN follow-up) -----------------------
        sl, tp = _resolve_brackets(s, is_buy, fill_price, sl_price, tp_price)
        if sl or tp:
            _attach_brackets(s, ticket, sl, tp)

        return {"ok": True, "detail": "opened", "ticket": ticket, "price": fill_price}


def _resolve_brackets(symbol, is_buy, price, sl_price, tp_price):
    """Prefer explicit prices; else derive from fixed points config."""
    info = mt5.symbol_info(symbol)
    pt = info.point
    sl = sl_price or 0.0
    tp = tp_price or 0.0
    if sl <= 0 and settings.sl_points > 0:
        sl = price - settings.sl_points * pt if is_buy else price + settings.sl_points * pt
    if tp <= 0 and settings.tp_points > 0:
        tp = price + settings.tp_points * pt if is_buy else price - settings.tp_points * pt
    digits = info.digits
    return (round(sl, digits) if sl > 0 else 0.0,
            round(tp, digits) if tp > 0 else 0.0)


def _attach_brackets(symbol, ticket, sl, tp) -> bool:
    for attempt in range(1, settings.modify_retries + 1):
        req = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": symbol,
            "position": ticket,
            "sl": sl,
            "tp": tp,
        }
        res = mt5.order_send(req)
        if res is not None and res.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"[modify] OK sl={sl} tp={tp} (attempt {attempt})")
            return True
        print(f"[modify] retry {attempt}/{settings.modify_retries} "
              f"retcode={getattr(res, 'retcode', None)}")
        time.sleep(0.05)
    print("[modify] ERROR: position left NAKED, manage manually!")
    return False


def close_all(symbol: Optional[str] = None) -> dict:
    s = _sym(symbol)
    with _lock:
        positions = mt5.positions_get(symbol=s) or []
        closed = 0
        for p in positions:
            if p.magic != settings.magic:
                continue
            tick = mt5.symbol_info_tick(s)
            is_buy = p.type == mt5.POSITION_TYPE_BUY
            req = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": s,
                "position": p.ticket,
                "volume": p.volume,
                "type": mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
                "price": tick.bid if is_buy else tick.ask,
                "deviation": settings.deviation_pts,
                "magic": settings.magic,
                "type_filling": _filling_mode(s),
            }
            res = mt5.order_send(req)
            if res is not None and res.retcode == mt5.TRADE_RETCODE_DONE:
                closed += 1
        return {"ok": True, "detail": f"closed {closed} position(s)"}


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
def _normalize_lot(symbol: str, lot: float) -> float:
    info = mt5.symbol_info(symbol)
    step = info.volume_step or 0.01
    lot = max(info.volume_min, min(info.volume_max, lot))
    return round(round(lot / step) * step, 2)


def _find_position_ticket(symbol: str) -> Optional[int]:
    positions = mt5.positions_get(symbol=symbol) or []
    own = [p for p in positions if p.magic == settings.magic]
    if not own:
        return None
    return max(own, key=lambda p: p.time).ticket  # the most recent one
