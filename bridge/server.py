"""
SpirCore-AutoTrader :: Phase 2 - Local Python Bridge
FastAPI local middleware server.

Endpoints
  GET  /health          -> liveness
  GET  /status          -> MT5 terminal + account + spread snapshot
  POST /webhook         -> ingest a TradingView / browser alert (JSON Signal)
  WS   /ws              -> persistent low-latency channel for the Chrome
                           extension (Phase 3). Sends/receives JSON Signals.

Security
  Every signal (webhook body or WS message) must carry `secret` matching
  BRIDGE_AUTH_TOKEN. The server binds to 127.0.0.1 by default so it is not
  reachable off-machine.

Run
  uvicorn server:app --host 127.0.0.1 --port 8000
  (or: python server.py)
"""
from __future__ import annotations

import asyncio
import contextlib
import csv
import json
import os

from fastapi import FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from pydantic import ValidationError

import commands as ea_commands
import mt5_client
import notify
from config import settings
from levels import write_levels
from models import Control, Result, Signal

DASHBOARD_HTML = os.path.join(os.path.dirname(__file__), "dashboard.html")


# ---------------------------------------------------------------------------
# App + lifespan (connect/disconnect MT5 once)
# ---------------------------------------------------------------------------
async def _management_loop():
    """Periodically apply break-even / trailing to open positions."""
    interval = max(0.5, settings.manage_interval_sec)
    while True:
        try:
            await asyncio.to_thread(mt5_client.manage_positions)
        except Exception as exc:  # never let the loop die
            print(f"[manage] error: {exc}")
        await asyncio.sleep(interval)


def notify_bg(text: str) -> None:
    """Fire a notification without blocking the event loop or the caller."""
    if notify.enabled():
        asyncio.create_task(asyncio.to_thread(notify.send, text))


def _journal_row_count() -> int:
    try:
        with open(settings.journal_file, encoding="utf-8") as fh:
            return max(0, sum(1 for _ in fh) - 1)  # minus header
    except FileNotFoundError:
        return 0


async def _journal_watch_loop():
    """Notify on newly closed trades (covers EA auto-trades and bridge trades)."""
    last = _journal_row_count()
    while True:
        await asyncio.sleep(5.0)
        if not notify.enabled():
            last = _journal_row_count()
            continue
        try:
            count = _journal_row_count()
            if count > last:
                new_rows = []
                with open(settings.journal_file, encoding="utf-8") as fh:
                    new_rows = fh.read().splitlines()[1:]  # drop header
                for row in new_rows[last:count]:
                    cols = row.split(",")
                    if len(cols) >= 6:
                        notify.send(f"Trade closed: {cols[2]} {cols[3]} @ {cols[4]} "
                                    f"P/L {cols[5]} ({cols[8] if len(cols) > 8 else ''})",
                                    subject="SpirCore: trade closed")
                last = count
        except Exception as exc:  # never let the loop die
            print(f"[journal-watch] error: {exc}")


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    mt5_client.connect()
    print(f"[bridge] MT5 connected | symbol={settings.symbol} | "
          f"listening on {settings.host}:{settings.port}")
    tasks = [asyncio.create_task(_management_loop()),
             asyncio.create_task(_journal_watch_loop())]
    if notify.enabled():
        notify_bg("SpirCore bridge started.")
    try:
        yield
    finally:
        for t in tasks:
            t.cancel()
        for t in tasks:
            with contextlib.suppress(asyncio.CancelledError):
                await t
        mt5_client.shutdown()
        print("[bridge] MT5 disconnected")


app = FastAPI(title="SpirCore Bridge", version="1.0", lifespan=lifespan)


# ---------------------------------------------------------------------------
# Core signal handler (shared by webhook + websocket)
# ---------------------------------------------------------------------------
def process_signal(sig: Signal) -> Result:
    if sig.secret != settings.auth_token:
        return Result(ok=False, action=sig.action, detail="unauthorized")

    symbol = sig.symbol or settings.symbol

    if sig.action in ("buy", "sell"):
        res = mt5_client.open_ecn(
            action=sig.action,
            symbol=symbol,
            lot=sig.lot,
            sl_price=sig.sl or 0.0,
            tp_price=sig.tp or 0.0,
            comment=sig.comment or "spircore-bridge",
        )
        # Alert on the outcome (opened, or blocked by spread / risk guard).
        verb = "opened" if res["ok"] else "blocked"
        notify_bg(f"{sig.action.upper()} {symbol} {verb}: {res['detail']}")
        return Result(ok=res["ok"], action=sig.action, detail=res["detail"],
                      ticket=res.get("ticket"), price=res.get("price"))

    if sig.action == "close":
        res = mt5_client.close_all(symbol)
        return Result(ok=res["ok"], action="close", detail=res["detail"])

    if sig.action == "draw":
        if not sig.levels:
            return Result(ok=False, action="draw", detail="no levels provided")
        path = write_levels(sig.levels)
        return Result(ok=True, action="draw",
                      detail=f"wrote {len(sig.levels)} level(s) -> {path}")

    return Result(ok=False, action=sig.action, detail="unknown action")


# ---------------------------------------------------------------------------
# HTTP endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    return {"ok": True, "service": "spircore-bridge"}


@app.get("/status")
def status():
    return {
        "terminal": mt5_client.terminal_status(),
        "symbol": settings.symbol,
        "spread_points": mt5_client.spread_points(),
        "max_spread_points": settings.max_spread_pts,
        "open_positions": mt5_client.count_own_positions(),
    }


@app.get("/dashboard")
def dashboard():
    """Serve the single-page dashboard (also opened by the Chrome extension)."""
    return FileResponse(DASHBOARD_HTML, media_type="text/html")


@app.get("/positions")
def positions():
    return {"positions": mt5_client.positions_list()}


@app.get("/journal")
def journal(limit: int = 500):
    """Return the most recent journal rows the EA has written."""
    rows = []
    try:
        with open(settings.journal_file, newline="", encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh))
    except FileNotFoundError:
        pass
    return {"rows": rows[-limit:]}


def _snapshot() -> dict:
    """One live frame for the dashboard."""
    return {
        "terminal": mt5_client.terminal_status(),
        "account": mt5_client.account_snapshot(),
        "symbol": settings.symbol,
        "spread_points": mt5_client.spread_points(),
        "max_spread_points": settings.max_spread_pts,
        "positions": mt5_client.positions_list(),
        "daily_pnl": mt5_client.daily_pnl(),
        "trades_today": mt5_client.trades_today(),
        "ea": ea_commands.read_status(),
    }


@app.get("/snapshot")
def snapshot():
    return _snapshot()


@app.post("/control")
async def control(ctl: Control):
    if ctl.secret != settings.auth_token:
        raise HTTPException(status_code=401, detail="unauthorized")

    a = ctl.action
    if a == "close_all":
        return mt5_client.close_all()
    if a == "close_ticket":
        if ctl.ticket is None:
            return {"ok": False, "detail": "ticket required"}
        return mt5_client.close_ticket(ctl.ticket)
    if a == "flatten":
        # Immediate close via the bridge AND tell the EA to stand down.
        res = mt5_client.close_all()
        ea_commands.write_command("FLATTEN")
        notify_bg("⚠️ FLATTEN triggered: closed all + EA automation OFF")
        return {"ok": True, "detail": f"flatten: {res['detail']} + EA stand-down"}
    if a == "ea_auto":
        return ea_commands.write_command("AUTO", (ctl.value or "OFF").upper())
    if a == "ea_strategy":
        v = (ctl.value or "").upper()
        # HYBRID / AUTO are selection modes; anything else is a single strategy.
        if v in ("HYBRID", "AUTO"):
            return ea_commands.write_command("MODE", v)
        return ea_commands.write_command("STRATEGY", v)
    if a == "ea_risk_daily":
        return ea_commands.write_command("RISK", "MAX_DAILY", ctl.value or "0")
    if a in ("open_buy", "open_sell"):
        return mt5_client.open_ecn(
            action="buy" if a == "open_buy" else "sell",
            lot=ctl.lot,
            sl_price=ctl.sl or 0.0,
            tp_price=ctl.tp or 0.0,
            comment="dashboard-manual",
        )
    if a == "modify":
        if ctl.ticket is None:
            return {"ok": False, "detail": "ticket required"}
        return mt5_client.modify_position(ctl.ticket, ctl.sl or 0.0, ctl.tp or 0.0)
    return {"ok": False, "detail": "unknown action"}


@app.websocket("/dashboard-ws")
async def dashboard_ws(ws: WebSocket):
    await ws.accept()
    try:
        while True:
            await ws.send_json(_snapshot())
            await asyncio.sleep(1.0)
    except WebSocketDisconnect:
        pass
    except Exception:
        with contextlib.suppress(Exception):
            await ws.close()


@app.post("/webhook", response_model=Result)
async def webhook(sig: Signal, x_auth_token: str | None = Header(default=None)):
    # Allow the secret via header too (handy for TradingView templates).
    if x_auth_token and not sig.secret:
        sig = sig.model_copy(update={"secret": x_auth_token})
    result = process_signal(sig)
    if not result.ok and result.detail == "unauthorized":
        raise HTTPException(status_code=401, detail="unauthorized")
    return result


# ---------------------------------------------------------------------------
# WebSocket endpoint (Chrome extension, Phase 3)
# ---------------------------------------------------------------------------
@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    print("[ws] client connected")
    try:
        while True:
            raw = await ws.receive_text()
            try:
                data = json.loads(raw)
                if data.get("action") == "ping":
                    await ws.send_json({"ok": True, "action": "ping", "detail": "pong"})
                    continue
                sig = Signal(**data)
            except (json.JSONDecodeError, ValidationError) as exc:
                await ws.send_json({"ok": False, "detail": f"bad message: {exc}"})
                continue
            result = process_signal(sig)
            await ws.send_json(result.model_dump())
    except WebSocketDisconnect:
        print("[ws] client disconnected")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=settings.host, port=settings.port)
