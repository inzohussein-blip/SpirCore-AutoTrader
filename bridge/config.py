"""
SpirCore-AutoTrader :: Phase 2 - Local Python Bridge
Configuration loader.

All settings come from environment variables (see .env.example).
Values are read once at import time into a frozen Settings instance.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

try:
    from dotenv import load_dotenv
    load_dotenv()  # load a local .env if present (never commit real secrets)
except ImportError:
    # python-dotenv is optional; without it we simply read os.environ directly.
    # This keeps config importable with the standard library alone (e.g. tests/CI).
    pass


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
    # Risk guard (mirrors the EA): 0 disables the check.
    max_daily_loss_pct: float = _get_float("MAX_DAILY_LOSS_PCT", 5.0)
    max_trades_per_day: int = _get_int("MAX_TRADES_PER_DAY", 10)
    # Total exposure cap across all EA positions (0 = unlimited).
    max_total_lots: float = _get_float("MAX_TOTAL_LOTS", 0.0)
    # Trading-session filter (kill-switch by hour, local time). Disabled by default.
    use_session_filter: bool = _get("USE_SESSION_FILTER", "false").lower() == "true"
    session_start_hour: int = _get_int("SESSION_START_HOUR", 0)
    session_end_hour: int = _get_int("SESSION_END_HOUR", 24)

    # --- Position management (mirrors the EA) ---
    use_break_even: bool = _get("USE_BREAK_EVEN", "true").lower() == "true"
    be_trigger_pts: int = _get_int("BE_TRIGGER_PTS", 300)
    be_lock_pts: int = _get_int("BE_LOCK_PTS", 20)
    use_trailing: bool = _get("USE_TRAILING", "true").lower() == "true"
    trail_start_pts: int = _get_int("TRAIL_START_PTS", 400)
    trail_dist_pts: int = _get_int("TRAIL_DIST_PTS", 250)
    trail_step_pts: int = _get_int("TRAIL_STEP_PTS", 30)
    manage_interval_sec: float = _get_float("MANAGE_INTERVAL_SEC", 2.0)

    # --- Chart-drawing bridge (Python -> EA) ---
    # File the EA polls to draw Python-pushed levels. Point this at the
    # terminal's MQL5/Files folder so the EA can read it locally.
    levels_file: str = _get("LEVELS_FILE", "spircore_levels.csv")

    # --- Reverse command bridge (dashboard -> Python -> EA) ---
    # File the EA polls for control commands (AUTO ON/OFF, strategy, risk,
    # close, flatten). Put it in the same MQL5/Files folder as the levels.
    commands_file: str = _get("COMMANDS_FILE", "spircore_commands.csv")
    # Journal file the EA writes (for the dashboard to read stats from).
    journal_file: str = _get("JOURNAL_FILE", "spircore_journal.csv")
    # Status file the EA writes (auto,mode,strategy) so the dashboard/extension
    # reflect the EA's real state.
    status_file: str = _get("STATUS_FILE", "spircore_status.csv")

    # --- Notifications (all optional; empty = channel disabled) ---
    tg_token: str = _get("TELEGRAM_TOKEN", "")
    tg_chat_id: str = _get("TELEGRAM_CHAT_ID", "")
    smtp_host: str = _get("SMTP_HOST", "")
    smtp_port: int = _get_int("SMTP_PORT", 587)
    smtp_user: str = _get("SMTP_USER", "")
    smtp_password: str = _get("SMTP_PASSWORD", "")
    smtp_tls: bool = _get("SMTP_TLS", "true").lower() == "true"
    email_from: str = _get("EMAIL_FROM", "")
    email_to: str = _get("EMAIL_TO", "")

    # --- SaaS performance push (optional; empty = disabled) ---
    saas_url: str = _get("SAAS_URL", "")
    saas_license_key: str = _get("SAAS_LICENSE_KEY", "")


settings = Settings()
