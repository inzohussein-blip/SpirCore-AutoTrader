"""Small dependency-free helpers shared across the bridge (safe to unit-test)."""
from __future__ import annotations


def in_session(hour: int, start: int, end: int) -> bool:
    """Is `hour` within the trading window [start, end)?
    A start > end window wraps across midnight (e.g. 22 -> 6)."""
    return (start <= hour < end) if start <= end else (hour >= start or hour < end)
