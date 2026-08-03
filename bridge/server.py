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

import contextlib
import json

from fastapi import FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

import mt5_client
from config import settings
from levels import write_levels
from models import Result, Signal


# ---------------------------------------------------------------------------
# App + lifespan (connect/disconnect MT5 once)
# ---------------------------------------------------------------------------
@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    mt5_client.connect()
    print(f"[bridge] MT5 connected | symbol={settings.symbol} | "
          f"listening on {settings.host}:{settings.port}")
    try:
        yield
    finally:
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
