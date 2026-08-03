"""
SpirCore-AutoTrader :: Phase 2 - Local Python Bridge
Python -> EA chart-drawing bridge.

The MetaTrader5 Python library cannot draw objects on a chart; only the EA
can. So the bridge writes requested levels to a small CSV file that the EA
polls (from its MQL5/Files folder) and renders as dashed lines.

CSV format (one level per line):
    <price>,<label>
e.g.
    3358.40,PY_UP
    3341.10,PY_DN
"""
from __future__ import annotations

import os

from config import settings


def write_levels(levels: list[float], label_prefix: str = "PY") -> str:
    """Overwrite the levels file with the given prices. Returns the path."""
    path = settings.levels_file
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    lines = [f"{price:.5f},{label_prefix}_{i}" for i, price in enumerate(levels)]
    # atomic-ish write: temp then replace, so the EA never reads a half file
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, path)
    return path
