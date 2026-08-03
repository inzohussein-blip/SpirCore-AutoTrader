"""
SpirCore-AutoTrader :: Phase 2 - Local Python Bridge
Request/response schemas for incoming signals.
"""
from __future__ import annotations

from typing import Literal, Optional
from pydantic import BaseModel, Field


class Signal(BaseModel):
    """
    A single instruction coming from TradingView / the Chrome extension.

    action:
      buy / sell -> open a market position (ECN style) on the symbol.
      close      -> close all EA/bridge positions on the symbol.
      draw       -> push horizontal levels to the EA to render on-chart.
    """
    secret: str = Field(..., description="Shared auth token; must match BRIDGE_AUTH_TOKEN")
    action: Literal["buy", "sell", "close", "draw"]
    symbol: Optional[str] = Field(None, description="Override default symbol")

    # execution options (all optional; fall back to config defaults)
    lot: Optional[float] = Field(None, gt=0)
    sl: Optional[float] = Field(None, description="Absolute SL price (0/None = use points)")
    tp: Optional[float] = Field(None, description="Absolute TP price (0/None = use points)")
    comment: Optional[str] = None

    # for action == "draw"
    levels: Optional[list[float]] = Field(None, description="Prices to draw as dashed lines")


class Result(BaseModel):
    ok: bool
    action: str
    detail: str = ""
    ticket: Optional[int] = None
    price: Optional[float] = None
