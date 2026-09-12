"""Unit tests for the SaaS data layer (stdlib sqlite3, no web framework)."""
import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))  # saas/
import db  # noqa: E402


class TestSaasDB(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(tempfile.mkdtemp(), "t.db")
        db.init_db(self.path)

    def test_user_create_idempotent(self):
        u1 = db.create_user("A@X.com", self.path)
        u2 = db.create_user("a@x.com", self.path)  # same email, normalized
        self.assertEqual(u1["id"], u2["id"])
        self.assertTrue(u2.get("existing"))

    def test_license_issue_and_validate(self):
        u = db.create_user("t@x.com", self.path)
        lic = db.issue_license(u["id"], "12345", "pro", 30, self.path)
        self.assertTrue(lic["key"].startswith("SPIR-"))
        v = db.validate_license(lic["key"], "12345", self.path)
        self.assertTrue(v["valid"])
        self.assertEqual(v["plan"], "pro")

    def test_account_binding(self):
        u = db.create_user("t2@x.com", self.path)
        lic = db.issue_license(u["id"], "111", "std", 30, self.path)
        self.assertFalse(db.validate_license(lic["key"], "999", self.path)["valid"])
        self.assertEqual(
            db.validate_license(lic["key"], "999", self.path)["reason"], "account mismatch")

    def test_revoke_and_unknown(self):
        u = db.create_user("t3@x.com", self.path)
        lic = db.issue_license(u["id"], "", "std", 30, self.path)
        self.assertTrue(db.revoke_license(lic["key"], self.path))
        self.assertFalse(db.validate_license(lic["key"], "", self.path)["valid"])
        self.assertEqual(db.validate_license("nope", "", self.path)["reason"], "unknown key")

    def test_expiry(self):
        u = db.create_user("t4@x.com", self.path)
        lic = db.issue_license(u["id"], "", "std", 30, self.path)
        db.set_license_expiry(lic["key"], int(time.time()) - 10, self.path)  # in the past
        v = db.validate_license(lic["key"], "", self.path)
        self.assertFalse(v["valid"])
        self.assertEqual(v["reason"], "expired")

    def test_list_all_licenses(self):
        ua = db.create_user("a@x.com", self.path)
        ub = db.create_user("b@x.com", self.path)
        db.issue_license(ua["id"], "111", "std", 30, self.path)
        db.issue_license(ub["id"], "222", "pro", 30, self.path)
        rows = db.list_all_licenses(self.path)
        self.assertEqual(len(rows), 2)
        emails = {r["email"] for r in rows}
        self.assertEqual(emails, {"a@x.com", "b@x.com"})
        self.assertIn("key", rows[0])

    def test_signals_publish_and_fetch(self):
        ch = "SPIR-master"
        s1 = db.publish_signal(ch, "buy", "XAUUSD", 0.1, 0, 0, "", self.path)
        s2 = db.publish_signal(ch, "sell", "XAUUSD", 0.2, 0, 0, "", self.path)
        self.assertGreater(s2["id"], s1["id"])
        # fetch since 0 -> both, oldest first
        all_sigs = db.fetch_signals(ch, 0, path=self.path)
        self.assertEqual([s["action"] for s in all_sigs], ["buy", "sell"])
        # fetch since s1 -> only the newer one
        newer = db.fetch_signals(ch, s1["id"], path=self.path)
        self.assertEqual(len(newer), 1)
        self.assertEqual(newer[0]["id"], s2["id"])
        # latest
        self.assertEqual(db.latest_signal(ch, self.path)["action"], "sell")
        # other channel is isolated
        self.assertEqual(db.fetch_signals("other", 0, path=self.path), [])

    def test_performance_roundtrip(self):
        u = db.create_user("t5@x.com", self.path)
        lic = db.issue_license(u["id"], "", "std", 30, self.path)
        db.record_performance(lic["key"], {"net": 100.5, "trades": 12, "win_rate": 55.0,
                                           "profit_factor": 1.4, "max_dd": -20.0,
                                           "equity_json": "[]"}, self.path)
        p = db.get_performance(lic["key"], self.path)
        self.assertEqual(p["trades"], 12)
        self.assertAlmostEqual(p["profit_factor"], 1.4)
        # upsert: second write updates in place
        db.record_performance(lic["key"], {"net": 200.0, "trades": 20}, self.path)
        self.assertEqual(db.get_performance(lic["key"], self.path)["trades"], 20)


if __name__ == "__main__":
    unittest.main()
