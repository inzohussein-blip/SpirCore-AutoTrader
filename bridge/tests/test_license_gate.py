"""Unit tests for the dashboard license gate.

MetaTrader5 is Windows-only and absent in CI, so we inject a stub module
before importing `server` (the gate decision never calls into MT5 — it
raises 403 first). We drive the gate by seeding the license cache, so the
tests make no network calls.
"""
import importlib
import os
import sys
import tempfile
import time
import types
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))  # bridge/

# --- Stub MetaTrader5 so `import server` works off-Windows. ---
sys.modules.setdefault("MetaTrader5", types.ModuleType("MetaTrader5"))

# Keep EA command/status writes out of the repo dir.
_d = tempfile.mkdtemp()
os.environ["COMMANDS_FILE"] = os.path.join(_d, "cmd.csv")
os.environ["STATUS_FILE"] = os.path.join(_d, "status.csv")

# Configure SaaS so the gate is "configured" (values are never dialled here;
# we seed the cache directly in each test).
os.environ["SAAS_URL"] = "http://saas.test"
os.environ["SAAS_LICENSE_KEY"] = "TESTKEY"
os.environ["LICENSE_GATE"] = "true"

import config  # noqa: E402
importlib.reload(config)
import server  # noqa: E402
importlib.reload(server)

from fastapi.testclient import TestClient  # noqa: E402

TOK = config.settings.auth_token


def _seed(status: dict) -> None:
    """Force the next _license_status() to return `status` (no network)."""
    server._license_cache.update({"at": time.time(), "status": status})


VALID = {"configured": True, "valid": True, "plan": "pro", "expiry": "2030-01-01",
         "channel": "CHAN", "dashboard_url": "http://x/dashboard", "reason": "ok"}
EXPIRED = {"configured": True, "valid": False, "plan": None, "expiry": None,
           "channel": None, "dashboard_url": None, "reason": "expired"}


class TestLicenseGate(unittest.TestCase):
    def setUp(self):
        # TestClient without `with` -> lifespan (MT5 connect) does not run.
        self.c = TestClient(server.app)

    def test_blocks_decision(self):
        _seed(VALID)
        self.assertFalse(server._license_blocks_new_exposure())
        _seed(EXPIRED)
        self.assertTrue(server._license_blocks_new_exposure())

    def test_license_endpoint(self):
        _seed(EXPIRED)
        r = self.c.get("/license")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertTrue(j["configured"])
        self.assertFalse(j["valid"])
        self.assertTrue(j["blocks_new"])
        self.assertEqual(j["reason"], "expired")

    def test_open_blocked_when_expired(self):
        _seed(EXPIRED)
        r = self.c.post("/control", json={"secret": TOK, "action": "open_buy", "lot": 0.1})
        self.assertEqual(r.status_code, 403)
        self.assertIn("license", r.json()["detail"])

    def test_auto_on_blocked_but_off_allowed(self):
        _seed(EXPIRED)
        on = self.c.post("/control", json={"secret": TOK, "action": "ea_auto", "value": "ON"})
        self.assertEqual(on.status_code, 403)
        # AUTO OFF is risk-reducing -> never gated (reaches the EA command writer).
        off = self.c.post("/control", json={"secret": TOK, "action": "ea_auto", "value": "OFF"})
        self.assertEqual(off.status_code, 200)

    def test_gate_off_allows_open(self):
        # When the gate is disabled, an expired license does not block.
        os.environ["LICENSE_GATE"] = "false"
        importlib.reload(config)
        importlib.reload(server)
        _seed(EXPIRED)
        self.assertFalse(server._license_blocks_new_exposure())
        os.environ["LICENSE_GATE"] = "true"
        importlib.reload(config)
        importlib.reload(server)

    def test_bad_token_still_401(self):
        _seed(VALID)
        r = self.c.post("/control", json={"secret": "wrong", "action": "close_all"})
        self.assertEqual(r.status_code, 401)


if __name__ == "__main__":
    unittest.main()
