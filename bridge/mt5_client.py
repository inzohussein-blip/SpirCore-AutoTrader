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
from util import in_session

_lock = threading.Lock()


# ---------------------------------------------------------------------------
# Connection lifecycle
# ---------------------------------------------------------------------------
def _init_kwargs() -> dict:
    kwargs = {}
    if settings.mt5_path:
        kwargs["path"] = settings.mt5_path
    if settings.mt5_login:
        kwargs.update(
            login=settings.mt5_login,
            password=settings.mt5_password,
            server=settings.mt5_server,
        )
    return kwargs


def connect() -> None:
    """Initialize the terminal connection. Raises RuntimeError on failure."""
    if not mt5.initialize(**_init_kwargs()):
        raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")
    if not mt5.symbol_select(settings.symbol, True):
        raise RuntimeError(f"Could not select symbol {settings.symbol}")


def ensure_connected() -> bool:
    """Watchdog: reconnect if the terminal link dropped. Returns True if up."""
    info = mt5.terminal_info()
    if info is not None and info.connected:
        return True
    with _lock:
        # Re-check under the lock, then attempt a re-initialize.
        info = mt5.terminal_info()
        if info is not None and info.connected:
            return True
        print("[watchdog] MT5 link down -> reinitializing")
        try:
            mt5.initialize(**_init_kwargs())
            mt5.symbol_select(settings.symbol, True)
        except Exception as exc:  # noqa: BLE001
            print(f"[watchdog] reinit error: {exc}")
        info = mt5.terminal_info()
        return bool(info and info.connected)


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


def positions_list(symbol: Optional[str] = None) -> list:
    """Open positions for this EA, as plain dicts for the dashboard."""
    s = _sym(symbol)
    out = []
    for p in mt5.positions_get(symbol=s) or []:
        if p.magic != settings.magic:
            continue
        out.append({
            "ticket": p.ticket,
            "type": "buy" if p.type == mt5.POSITION_TYPE_BUY else "sell",
            "volume": p.volume,
            "price_open": p.price_open,
            "sl": p.sl,
            "tp": p.tp,
            "profit": p.profit,
            "swap": p.swap,
        })
    return out


def modify_position(ticket: int, sl: float, tp: float) -> dict:
    """Set absolute SL/TP prices on one position (0 leaves that bracket off)."""
    with _lock:
        pos = mt5.positions_get(ticket=ticket)
        if not pos:
            return {"ok": False, "detail": "position not found"}
        p = pos[0]
        if p.magic != settings.magic:
            return {"ok": False, "detail": "not an EA position"}
        info = mt5.symbol_info(p.symbol)
        digits = info.digits if info else 2
        req = {
            "action": mt5.TRADE_ACTION_SLTP,
            "symbol": p.symbol,
            "position": p.ticket,
            "sl": round(sl, digits) if sl and sl > 0 else 0.0,
            "tp": round(tp, digits) if tp and tp > 0 else 0.0,
        }
        res = mt5.order_send(req)
        ok = res is not None and res.retcode == mt5.TRADE_RETCODE_DONE
        return {"ok": ok, "detail": "modified" if ok else f"retcode={getattr(res,'retcode',None)}"}


def account_snapshot() -> dict:
    acc = mt5.account_info()
    return {
        "balance": acc.balance if acc else None,
        "equity": acc.equity if acc else None,
        "profit": acc.profit if acc else None,
        "margin_free": acc.margin_free if acc else None,
        "currency": acc.currency if acc else "",
    }


def close_ticket(ticket: int, symbol: Optional[str] = None) -> dict:
    """Close a single position by ticket."""
    s = _sym(symbol)
    with _lock:
        pos = mt5.positions_get(ticket=ticket)
        if not pos:
            return {"ok": False, "detail": "position not found"}
        p = pos[0]
        if p.magic != settings.magic:
            return {"ok": False, "detail": "not an EA position"}
        tick = mt5.symbol_info_tick(p.symbol)
        is_buy = p.type == mt5.POSITION_TYPE_BUY
        req = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": p.symbol,
            "position": p.ticket,
            "volume": p.volume,
            "type": mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
            "price": tick.bid if is_buy else tick.ask,
            "deviation": settings.deviation_pts,
            "magic": settings.magic,
            "type_filling": _filling_mode(p.symbol),
        }
        res = mt5.order_send(req)
        ok = res is not None and res.retcode == mt5.TRADE_RETCODE_DONE
        return {"ok": ok, "detail": "closed" if ok else f"retcode={getattr(res,'retcode',None)}"}


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


def session_ok() -> bool:
    """True if trading is allowed now (session-hours kill-switch)."""
    if not settings.use_session_filter:
        return True
    return in_session(datetime.now().hour,
                      settings.session_start_hour, settings.session_end_hour)


def total_lots(symbol: Optional[str] = None) -> float:
    s = _sym(symbol)
    return sum(p.volume for p in (mt5.positions_get(symbol=s) or [])
              if p.magic == settings.magic)


def risk_guard(symbol: Optional[str] = None, add_lots: float = 0.0) -> Optional[str]:
    """Return a block reason if a hard risk limit is hit, else None."""
    s = _sym(symbol)
    if not session_ok():
        return "outside trading session (kill-switch)"
    if settings.max_trades_per_day > 0 and trades_today(s) >= settings.max_trades_per_day:
        return "max trades/day reached"
    if settings.max_total_lots > 0 and (total_lots(s) + add_lots) > settings.max_total_lots:
        return f"max total lots {settings.max_total_lots} would be exceeded"
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

        info = mt5.symbol_info(s)
        tick = mt5.symbol_info_tick(s)
        if info is None or tick is None:
            return {"ok": False, "detail": "no market data"}

        volume = _normalize_lot(s, lot if lot else settings.default_lot)

        blocked = risk_guard(s, add_lots=volume)
        if blocked:
            print(f"[risk] BLOCK: {blocked}")
            return {"ok": False, "detail": f"risk guard: {blocked}"}
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


def manage_positions(symbol: Optional[str] = None) -> None:
    """
    Break-even + trailing-stop on this EA's open positions (mirrors the EA).
    Only ever moves the stop favorably; keeps TP. Called periodically by the
    server's background loop, so alert/bridge trades get the same management
    the EA gives its own trades.
    """
    if not settings.use_break_even and not settings.use_trailing:
        return

    s = _sym(symbol)
    info = mt5.symbol_info(s)
    tick = mt5.symbol_info_tick(s)
    if info is None or tick is None or info.point <= 0:
        return

    pt = info.point
    step = max(1, settings.trail_step_pts) * pt

    with _lock:
        for p in mt5.positions_get(symbol=s) or []:
            if p.magic != settings.magic:
                continue
            entry = p.price_open
            cur_sl = p.sl

            if p.type == mt5.POSITION_TYPE_BUY:
                profit_pts = (tick.bid - entry) / pt
                new_sl = cur_sl
                if settings.use_break_even and profit_pts >= settings.be_trigger_pts:
                    new_sl = max(new_sl, entry + settings.be_lock_pts * pt)
                if settings.use_trailing and profit_pts >= settings.trail_start_pts:
                    new_sl = max(new_sl, tick.bid - settings.trail_dist_pts * pt)
                if new_sl > cur_sl + step - pt and new_sl < tick.bid:
                    _modify_sl(s, p.ticket, round(new_sl, info.digits), p.tp)

            elif p.type == mt5.POSITION_TYPE_SELL:
                profit_pts = (entry - tick.ask) / pt
                sl = cur_sl if cur_sl > 0 else float("inf")
                if settings.use_break_even and profit_pts >= settings.be_trigger_pts:
                    sl = min(sl, entry - settings.be_lock_pts * pt)
                if settings.use_trailing and profit_pts >= settings.trail_start_pts:
                    sl = min(sl, tick.ask + settings.trail_dist_pts * pt)
                if sl != float("inf") and (cur_sl == 0 or sl < cur_sl - step + pt) and sl > tick.ask:
                    _modify_sl(s, p.ticket, round(sl, info.digits), p.tp)


def _modify_sl(symbol: str, ticket: int, sl: float, tp: float) -> None:
    req = {
        "action": mt5.TRADE_ACTION_SLTP,
        "symbol": symbol,
        "position": ticket,
        "sl": sl,
        "tp": tp,
    }
    mt5.order_send(req)


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
