"""
SpirCore-AutoTrader :: SaaS API (FastAPI)

Endpoints
  POST /signup                 - register a user by email
  POST /admin/license          - issue a license (admin token)         [admin]
  POST /admin/revoke           - revoke a license                       [admin]
  GET  /license/validate       - EA calls this to check its license     [public]
  POST /performance/report     - a licensed bridge pushes its stats
  GET  /p/{key}                - PUBLIC read-only performance page
  POST /billing/webhook        - Stripe webhook (SKELETON - see notes)

Run:  uvicorn app:app --host 0.0.0.0 --port 9000

Notes
  * SQLite via the standard library; no DB server needed to start.
  * Stripe billing is a SKELETON: wire real keys + signature verification
    before taking payments. Never commit real secrets.
"""
from __future__ import annotations

import html
import json
import os

from fastapi import Body, FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse

import db

ADMIN_TOKEN = os.getenv("SAAS_ADMIN_TOKEN", "change-me-admin")

app = FastAPI(title="SpirCore SaaS", version="1.0")


@app.on_event("startup")
def _startup():
    db.init_db()


def _require_admin(token: str | None):
    if token != ADMIN_TOKEN:
        raise HTTPException(status_code=401, detail="admin token required")


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------
@app.post("/signup")
def signup(email: str = Body(..., embed=True)):
    if "@" not in email:
        raise HTTPException(status_code=400, detail="invalid email")
    return db.create_user(email)


# ---------------------------------------------------------------------------
# Licensing
# ---------------------------------------------------------------------------
@app.post("/admin/license")
def admin_issue(
    email: str = Body(...),
    account: str = Body(""),
    plan: str = Body("standard"),
    days: int = Body(30),
    x_admin_token: str | None = Header(default=None),
):
    _require_admin(x_admin_token)
    user = db.get_user_by_email(email) or db.create_user(email)
    return db.issue_license(user["id"], account, plan, days)


@app.post("/admin/revoke")
def admin_revoke(key: str = Body(..., embed=True),
                 x_admin_token: str | None = Header(default=None)):
    _require_admin(x_admin_token)
    return {"revoked": db.revoke_license(key)}


@app.get("/license/validate")
def license_validate(key: str = Query(...), account: str = Query("")):
    """Called by the EA. Public by design; returns validity only."""
    return db.validate_license(key, account)


# ---------------------------------------------------------------------------
# Performance sharing
# ---------------------------------------------------------------------------
@app.post("/performance/report")
def performance_report(key: str = Body(...), stats: dict = Body(...)):
    # The license key itself authenticates the push (must be valid).
    v = db.validate_license(key)
    if not v["valid"]:
        raise HTTPException(status_code=401, detail=f"license {v['reason']}")
    db.record_performance(key, stats)
    return {"ok": True}


@app.get("/p/{key}", response_class=HTMLResponse)
def public_performance(key: str):
    perf = db.get_performance(key)
    return HTMLResponse(_render_public(key, perf))


# ---------------------------------------------------------------------------
# Billing (Stripe) - SKELETON
# ---------------------------------------------------------------------------
@app.post("/billing/webhook")
async def billing_webhook(payload: dict = Body(...)):
    """SKELETON. In production:
       1. Verify the Stripe-Signature header against your webhook secret.
       2. On 'checkout.session.completed' / 'invoice.paid', extend the
          customer's license expiry (db.set_license_expiry).
       3. On 'customer.subscription.deleted', revoke (db.revoke_license).
    This stub only echoes the event type so the wiring is testable.
    """
    return {"received": True, "type": payload.get("type", "unknown")}


# ---------------------------------------------------------------------------
# Public performance page (self-contained HTML)
# ---------------------------------------------------------------------------
def _render_public(key: str, perf: dict | None) -> str:
    disclaimer = ("Past performance does not guarantee future results. "
                  "Trading is high-risk. This page is informational only.")
    if not perf:
        body = "<p class='muted'>No performance data reported yet.</p>"
    else:
        pf = perf.get("profit_factor")
        pf_txt = "—" if pf is None else f"{pf:.2f}"
        def cell(label, val):
            return f"<div class='card'><div class='k'>{label}</div><div class='v'>{val}</div></div>"
        body = "<div class='grid'>" + "".join([
            cell("Net", f"{perf.get('net', 0):.2f}"),
            cell("Trades", perf.get("trades", 0)),
            cell("Win rate", f"{perf.get('win_rate', 0):.1f}%"),
            cell("Profit factor", pf_txt),
            cell("Max drawdown", f"{perf.get('max_dd', 0):.2f}"),
        ]) + "</div>"
    safe_key = html.escape(key[:12]) + "…"
    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SpirCore Performance</title>
<style>
  body{{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#0f1116;color:#e8e8ea;margin:0;padding:24px}}
  h1{{color:#d4af37;font-size:20px}} .muted{{color:#8a8f9c}}
  .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:14px;margin:18px 0}}
  .card{{background:#171a21;border:1px solid #2a2e38;border-radius:10px;padding:16px}}
  .k{{color:#8a8f9c;font-size:12px;text-transform:uppercase}} .v{{font-size:22px;font-weight:700;margin-top:6px}}
  .disc{{color:#8a8f9c;font-size:12px;border-top:1px solid #2a2e38;padding-top:12px;margin-top:18px}}
</style></head><body>
  <h1>⚡ SpirCore Performance</h1>
  <p class="muted">License {safe_key}</p>
  {body}
  <p class="disc">⚠️ {disclaimer}</p>
</body></html>"""
