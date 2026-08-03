"""
SpirCore-AutoTrader :: Phase 2 - Local Python Bridge
Configuration loader.

All settings come from environment variables (see .env.example).
Values are read once at import time into a frozen Settings instance.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from dotenv import load_dotenv

load_dotenv()  # load a local .env if present (never commit real secrets)


def _get(name: str, default: str = "") -> str:
    return os.getenv(name, default).strip()


def _get_int(name: str, default: int) -> int:
    try:
        return int(_get(name) or default)
    except ValueError:
        return default


def _get_float(name: str, default: float) -> float:
    try:
        return float(_get(name) or default)
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    # --- Network / server ---
    host: str = _get("BRIDGE_HOST", "127.0.0.1")   # localhost only by default (privacy)
    port: int = _get_int("BRIDGE_PORT", 8000)
    # Shared secret every incoming webhook / WS message must carry.
    auth_token: str = _get("BRIDGE_AUTH_TOKEN", "change-me")

    # --- MetaTrader 5 terminal login (optional if terminal already logged in) ---
    mt5_path: str = _get("MT5_PATH", "")            # path to terminal64.exe (optional)
    mt5_login: int = _get_int("MT5_LOGIN", 0)       # 0 = use the currently logged-in account
    mt5_password: str = _get("MT5_PASSWORD", "")
    mt5_server: str = _get("MT5_SERVER", "")

    # --- Trading defaults (mirror the EA) ---
    symbol: str = _get("SYMBOL", "XAUUSD")
    default_lot: float = _get_float("DEFAULT_LOT", 0.10)
    magic: int = _get_int("MAGIC", 990011)
    deviation_pts: int = _get_int("DEVIATION_PTS", 20)

    # --- Risk / safety ---
    max_spread_pts: int = _get_int("MAX_SPREAD_PTS", 30)   # spread filter (news / MM protection)
    sl_points: int = _get_int("SL_POINTS", 300)            # fixed-points fallback SL
    tp_points: int = _get_int("TP_POINTS", 600)            # fixed-points fallback TP
    modify_retries: int = _get_int("MODIFY_RETRIES", 3)
    max_positions: int = _get_int("MAX_POSITIONS", 1)

    # --- Chart-drawing bridge (Python -> EA) ---
    # File the EA polls to draw Python-pushed levels. Point this at the
    # terminal's MQL5/Files folder so the EA can read it locally.
    levels_file: str = _get("LEVELS_FILE", "spircore_levels.csv")


settings = Settings()
