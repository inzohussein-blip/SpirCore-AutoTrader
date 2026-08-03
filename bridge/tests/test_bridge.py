"""Unit tests for the reverse command bridge and notifications.

Sets env to temp paths and reloads config so the modules pick them up,
regardless of import order during test discovery.
"""
import importlib
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))  # bridge/

_d = tempfile.mkdtemp()
os.environ["COMMANDS_FILE"] = os.path.join(_d, "cmd.csv")
os.environ["STATUS_FILE"] = os.path.join(_d, "status.csv")
for _k in ("TELEGRAM_TOKEN", "TELEGRAM_CHAT_ID", "SMTP_HOST", "EMAIL_TO"):
    os.environ.pop(_k, None)

import config  # noqa: E402
importlib.reload(config)
import commands  # noqa: E402
importlib.reload(commands)
import notify  # noqa: E402
importlib.reload(notify)


class TestCommands(unittest.TestCase):
    def test_write_and_format(self):
        r = commands.write_command("AUTO", "ON")
        self.assertTrue(r["ok"])
        with open(os.environ["COMMANDS_FILE"], encoding="utf-8") as fh:
            line = fh.read().strip()
        parts = line.split(",")
        self.assertTrue(parts[0].isdigit())      # monotonic id
        self.assertEqual(parts[1], "AUTO")
        self.assertEqual(parts[2], "ON")

    def test_reject_unknown_command(self):
        self.assertFalse(commands.write_command("HACK")["ok"])

    def test_ids_increase(self):
        a = commands.write_command("MODE", "AUTO")["id"]
        b = commands.write_command("MODE", "HYBRID")["id"]
        self.assertGreaterEqual(b, a)

    def test_read_status_roundtrip(self):
        with open(os.environ["STATUS_FILE"], "w", encoding="utf-8") as fh:
            fh.write("ON,HYBRID,CEZLSMA\n")
        s = commands.read_status()
        self.assertEqual(s["auto"], "ON")
        self.assertEqual(s["mode"], "HYBRID")
        self.assertEqual(s["strategy"], "CEZLSMA")

    def test_read_status_missing_file(self):
        os.environ["STATUS_FILE"] = os.path.join(_d, "nope.csv")
        importlib.reload(config)
        importlib.reload(commands)
        s = commands.read_status()
        self.assertIsNone(s["mode"])


class TestNotify(unittest.TestCase):
    def test_disabled_is_noop(self):
        self.assertFalse(notify.enabled())
        notify.send("should not raise")  # no channels configured -> silent


class TestSession(unittest.TestCase):
    def test_normal_window(self):
        import util
        self.assertTrue(util.in_session(10, 8, 17))
        self.assertFalse(util.in_session(7, 8, 17))
        self.assertFalse(util.in_session(17, 8, 17))   # end is exclusive

    def test_midnight_wrap(self):
        import util
        self.assertTrue(util.in_session(23, 22, 6))
        self.assertTrue(util.in_session(2, 22, 6))
        self.assertFalse(util.in_session(12, 22, 6))


if __name__ == "__main__":
    unittest.main()
