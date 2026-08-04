"""
SpirCore-AutoTrader :: SaaS data layer (SQLite, standard library only).

Tables
  users        - registered accounts (by email)
  licenses     - a key bound to an MT5 account, with a plan and expiry
  performance  - the latest performance snapshot pushed per license

This layer holds all the logic (key generation, validation, expiry) so it
is fully unit-testable without the web framework.
"""
from __future__ import annotations

import os
import secrets
import sqlite3
import time
from typing import Optional

DB_PATH = os.getenv("SAAS_DB", "saas.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  email    TEXT UNIQUE NOT NULL,
  created  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS licenses (
  key      TEXT PRIMARY KEY,
  user_id  INTEGER NOT NULL,
  account  TEXT,                 -- MT5 account number the key is bound to (optional)
  plan     TEXT NOT NULL,
  expiry   INTEGER NOT NULL,     -- unix seconds
  active   INTEGER NOT NULL DEFAULT 1,
  created  INTEGER NOT NULL,
  FOREIGN KEY(user_id) REFERENCES users(id)
);
CREATE TABLE IF NOT EXISTS performance (
  license_key TEXT PRIMARY KEY,
  updated     INTEGER NOT NULL,
  net         REAL,
  trades      INTEGER,
  win_rate    REAL,
  profit_factor REAL,
  max_dd      REAL,
  equity_json TEXT
);
"""


def _conn(path: Optional[str] = None) -> sqlite3.Connection:
    c = sqlite3.connect(path or DB_PATH)
    c.row_factory = sqlite3.Row
    return c


def init_db(path: Optional[str] = None) -> None:
    with _conn(path) as c:
        c.executescript(SCHEMA)


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------
def create_user(email: str, path: Optional[str] = None) -> dict:
    email = email.strip().lower()
    with _conn(path) as c:
        try:
            cur = c.execute("INSERT INTO users(email, created) VALUES(?, ?)",
                            (email, int(time.time())))
            return {"id": cur.lastrowid, "email": email}
        except sqlite3.IntegrityError:
            row = c.execute("SELECT id, email FROM users WHERE email=?", (email,)).fetchone()
            return {"id": row["id"], "email": row["email"], "existing": True}


def get_user_by_email(email: str, path: Optional[str] = None) -> Optional[dict]:
    with _conn(path) as c:
        row = c.execute("SELECT id, email FROM users WHERE email=?",
                        (email.strip().lower(),)).fetchone()
        return dict(row) if row else None


# ---------------------------------------------------------------------------
# Licenses
# ---------------------------------------------------------------------------
def issue_license(user_id: int, account: str, plan: str, days: int,
                  path: Optional[str] = None) -> dict:
    key = "SPIR-" + secrets.token_urlsafe(18)
    expiry = int(time.time()) + days * 86400
    with _conn(path) as c:
        c.execute(
            "INSERT INTO licenses(key, user_id, account, plan, expiry, active, created) "
            "VALUES(?, ?, ?, ?, ?, 1, ?)",
            (key, user_id, account or None, plan, expiry, int(time.time())),
        )
    return {"key": key, "plan": plan, "expiry": expiry, "account": account or None}


def validate_license(key: str, account: str = "", path: Optional[str] = None) -> dict:
    """Core license check the EA calls. Returns {valid, reason, plan, expiry}."""
    with _conn(path) as c:
        row = c.execute("SELECT * FROM licenses WHERE key=?", (key,)).fetchone()
    if row is None:
        return {"valid": False, "reason": "unknown key"}
    if not row["active"]:
        return {"valid": False, "reason": "revoked"}
    if row["expiry"] < int(time.time()):
        return {"valid": False, "reason": "expired", "expiry": row["expiry"]}
    # If the key is bound to an account, it must match.
    if row["account"] and account and str(account) != str(row["account"]):
        return {"valid": False, "reason": "account mismatch"}
    return {"valid": True, "reason": "ok", "plan": row["plan"], "expiry": row["expiry"]}


def revoke_license(key: str, path: Optional[str] = None) -> bool:
    with _conn(path) as c:
        cur = c.execute("UPDATE licenses SET active=0 WHERE key=?", (key,))
        return cur.rowcount > 0


def set_license_expiry(key: str, expiry: int, path: Optional[str] = None) -> bool:
    with _conn(path) as c:
        cur = c.execute("UPDATE licenses SET expiry=?, active=1 WHERE key=?", (expiry, key))
        return cur.rowcount > 0


def list_licenses(user_id: int, path: Optional[str] = None) -> list:
    with _conn(path) as c:
        rows = c.execute("SELECT key, account, plan, expiry, active FROM licenses "
                         "WHERE user_id=? ORDER BY created DESC", (user_id,)).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Performance snapshots (pushed by a licensed bridge)
# ---------------------------------------------------------------------------
def record_performance(license_key: str, stats: dict, path: Optional[str] = None) -> None:
    with _conn(path) as c:
        c.execute(
            "INSERT INTO performance(license_key, updated, net, trades, win_rate, "
            "profit_factor, max_dd, equity_json) VALUES(?,?,?,?,?,?,?,?) "
            "ON CONFLICT(license_key) DO UPDATE SET updated=excluded.updated, "
            "net=excluded.net, trades=excluded.trades, win_rate=excluded.win_rate, "
            "profit_factor=excluded.profit_factor, max_dd=excluded.max_dd, "
            "equity_json=excluded.equity_json",
            (license_key, int(time.time()), stats.get("net"), stats.get("trades"),
             stats.get("win_rate"), stats.get("profit_factor"), stats.get("max_dd"),
             stats.get("equity_json")),
        )


def get_performance(license_key: str, path: Optional[str] = None) -> Optional[dict]:
    with _conn(path) as c:
        row = c.execute("SELECT * FROM performance WHERE license_key=?",
                        (license_key,)).fetchone()
        return dict(row) if row else None
