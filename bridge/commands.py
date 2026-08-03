"""
SpirCore-AutoTrader :: Reverse command bridge (dashboard -> Python -> EA)

The dashboard cannot talk to the EA directly. It POSTs control actions to
the bridge, which writes a single-line command file that the EA polls (from
its MQL5/Files folder) and executes.

Latest-command-wins model: every write overwrites the file with a fresh,
monotonically increasing id. The EA executes a command only when its id is
greater than the last one it ran, so a command is never executed twice and
a stale file is ignored.

File format (one line):
    <id>,<CMD>,<arg1>,<arg2>
e.g.
    1737045123456,AUTO,ON
    1737045130000,RISK,MAX_DAILY,3.0
    1737045140000,FLATTEN
"""
from __future__ import annotations

import os
import time

from config import settings

# Commands the EA understands (validated before writing).
VALID = {"AUTO", "STRATEGY", "RISK", "CLOSE", "FLATTEN"}


def write_command(cmd: str, *args: str) -> dict:
    cmd = cmd.upper()
    if cmd not in VALID:
        return {"ok": False, "detail": f"unknown command '{cmd}'"}

    cmd_id = int(time.time() * 1000)  # ms epoch -> monotonic enough for manual use
    parts = [str(cmd_id), cmd] + [str(a) for a in args]
    line = ",".join(parts)

    path = settings.commands_file
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(line + "\n")
    os.replace(tmp, path)  # atomic overwrite
    return {"ok": True, "detail": f"queued: {line}", "id": cmd_id}
