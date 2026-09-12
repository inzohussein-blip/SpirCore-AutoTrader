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


@app.get("/admin/licenses")
def admin_licenses(x_admin_token: str | None = Header(default=None)):
    _require_admin(x_admin_token)
    return {"licenses": db.list_all_licenses()}


@app.get("/admin", response_class=HTMLResponse)
def admin_page():
    """Admin console (license management). Auth is per-request via the token."""
    return HTMLResponse(_ADMIN_HTML)


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
# Copy-trading / signal distribution
# ---------------------------------------------------------------------------
@app.post("/signals/publish")
def signals_publish(
    key: str = Body(...),            # master (channel) license key
    action: str = Body(...),         # buy / sell / close
    symbol: str = Body(""),
    lot: float = Body(0.0),
    sl: float = Body(0.0),
    tp: float = Body(0.0),
    comment: str = Body(""),
):
    if action not in ("buy", "sell", "close"):
        raise HTTPException(status_code=400, detail="action must be buy/sell/close")
    v = db.validate_license(key)
    if not v["valid"]:
        raise HTTPException(status_code=401, detail=f"license {v['reason']}")
    return db.publish_signal(key, action, symbol, lot, sl, tp, comment)


@app.get("/signals/fetch")
def signals_fetch(key: str = Query(...), channel: str = Query(...),
                  since: int = Query(0)):
    """Follower polls here. `key` = follower's own valid license; `channel`
    = the master's key they subscribe to."""
    v = db.validate_license(key)
    if not v["valid"]:
        raise HTTPException(status_code=401, detail=f"license {v['reason']}")
    return {"signals": db.fetch_signals(channel, since)}


@app.get("/signals/latest")
def signals_latest(key: str = Query(...), channel: str = Query(...)):
    """Flat latest-signal endpoint -- easy for the follower EA to parse."""
    v = db.validate_license(key)
    if not v["valid"]:
        raise HTTPException(status_code=401, detail=f"license {v['reason']}")
    sig = db.latest_signal(channel)
    return sig or {"id": 0, "action": "none"}


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


# ---------------------------------------------------------------------------
# Admin console (self-contained HTML; auth via the admin token per request)
# ---------------------------------------------------------------------------
_ADMIN_HTML = """<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SpirCore Admin</title>
<style>
  :root{--gold:#d4af37;--bg:#0f1116;--panel:#171a21;--bd:#2a2e38;--tx:#e8e8ea;--mut:#8a8f9c;--red:#c0392b;--grn:#2e8b57}
  *{box-sizing:border-box} body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--tx);margin:0;padding:20px}
  h1{color:var(--gold);font-size:20px} .mut{color:var(--mut);font-size:12px}
  input,select,button{background:#0e1015;border:1px solid var(--bd);border-radius:6px;color:var(--tx);padding:7px 9px;font-size:13px}
  button{cursor:pointer;font-weight:600} .gold{background:var(--gold);color:#14161c;border:none}
  section{background:var(--panel);border:1px solid var(--bd);border-radius:10px;padding:16px;margin-top:14px}
  .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
  table{width:100%;border-collapse:collapse;margin-top:10px} th,td{text-align:left;padding:7px 9px;border-bottom:1px solid var(--bd);font-size:12px}
  th{color:var(--mut)} .exp{color:var(--red)} .ok{color:var(--grn)}
  code{font-size:11px;color:var(--gold)}
</style></head><body>
  <h1>⚡ SpirCore Admin</h1>
  <div class="row"><input id="tok" type="password" placeholder="admin token" style="width:220px">
    <button class="gold" onclick="save()">Save token</button>
    <span id="msg" class="mut"></span></div>

  <section>
    <h3 style="margin:0 0 10px">Issue license</h3>
    <div class="row">
      <input id="email" placeholder="email">
      <input id="account" placeholder="MT5 account (optional)" style="width:150px">
      <input id="plan" placeholder="plan" value="standard" style="width:110px">
      <input id="days" type="number" value="30" style="width:80px" title="days">
      <button class="gold" onclick="issue()">Issue</button>
    </div>
  </section>

  <section>
    <div class="row" style="justify-content:space-between">
      <h3 style="margin:0">Licenses</h3><button onclick="load()">Refresh</button>
    </div>
    <table><thead><tr><th>Key</th><th>Email</th><th>Account</th><th>Plan</th><th>Expiry</th><th>Status</th><th></th></tr></thead>
      <tbody id="rows"><tr><td colspan="7" class="mut">load to view</td></tr></tbody></table>
  </section>

<script>
const $=id=>document.getElementById(id);
let tok=localStorage.getItem("spir_admin")||""; $("tok").value=tok;
function save(){tok=$("tok").value;localStorage.setItem("spir_admin",tok);msg("token saved");load();}
function msg(t){$("msg").textContent=t;}
async function api(path,opts){opts=opts||{};opts.headers=Object.assign({"Content-Type":"application/json","x-admin-token":tok},opts.headers||{});
  const r=await fetch(path,opts);if(r.status===401){msg("unauthorized — check token");throw 0;}return r.json();}
async function issue(){
  try{const b={email:$("email").value,account:$("account").value,plan:$("plan").value,days:Number($("days").value)||30};
    const r=await api("/admin/license",{method:"POST",body:JSON.stringify(b)});msg("issued: "+r.key);load();}catch(e){}
}
async function revoke(k){ if(!confirm("Revoke "+k+"?"))return;
  try{await api("/admin/revoke",{method:"POST",body:JSON.stringify({key:k})});load();}catch(e){}
}
async function load(){
  try{const d=await api("/admin/licenses");const now=Date.now()/1000;
    $("rows").innerHTML=(d.licenses||[]).map(l=>{
      const exp=new Date(l.expiry*1000).toISOString().slice(0,10);
      const live=l.active&&l.expiry>now;
      return `<tr><td><code>${l.key.slice(0,16)}…</code></td><td>${l.email}</td><td>${l.account||"—"}</td>`+
        `<td>${l.plan}</td><td class="${l.expiry<now?'exp':''}">${exp}</td>`+
        `<td class="${live?'ok':'exp'}">${live?'active':(l.active?'expired':'revoked')}</td>`+
        `<td><button onclick="revoke('${l.key}')">Revoke</button></td></tr>`;
    }).join("")||'<tr><td colspan="7" class="mut">no licenses</td></tr>';
  }catch(e){}
}
if(tok) load();
</script>
</body></html>"""
