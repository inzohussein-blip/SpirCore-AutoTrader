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
