/*
 * SpirCore-AutoTrader :: Phase 3 - Chrome Extension
 * Popup UI logic: config editing + manual signal buttons + live status.
 */

const $ = (id) => document.getElementById(id);
const FIELDS = ["host", "port", "token", "symbol", "lot"];

function setStatus(connected) {
  const el = $("status");
  el.textContent = connected ? "online" : "offline";
  el.className = "status " + (connected ? "on" : "off");
}

function log(msg) {
  $("log").textContent = msg;
}

// --- Load stored config into the form ---
async function load() {
  const stored = await chrome.storage.local.get(FIELDS);
  $("host").value = stored.host ?? "127.0.0.1";
  $("port").value = stored.port ?? 8000;
  $("token").value = stored.token ?? "";
  $("symbol").value = stored.symbol ?? "XAUUSD";
  $("lot").value = stored.lot ?? 0.1;

  chrome.runtime.sendMessage({ type: "getStatus" }, (res) => {
    if (res) setStatus(res.connected);
  });
}

// --- Save config + tell the worker to reconnect ---
async function save() {
  const cfg = {
    host: $("host").value.trim() || "127.0.0.1",
    port: Number($("port").value) || 8000,
    token: $("token").value,
    symbol: $("symbol").value.trim() || "XAUUSD",
    lot: Number($("lot").value) || 0.1,
  };
  await chrome.storage.local.set(cfg);
  chrome.runtime.sendMessage({ type: "configUpdated" }, () => log("saved, reconnecting…"));
}

// --- Send a manual signal ---
function send(action) {
  chrome.runtime.sendMessage(
    { type: "signal", payload: { action } },
    (res) => log(res ? `${action}: ${res.detail}` : `${action}: no response`)
  );
}

// --- Live updates pushed by the worker ---
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === "status") setStatus(msg.connected);
  if (msg.type === "wsReply" && msg.payload) {
    const p = msg.payload;
    log(`${p.action ?? "reply"}: ${p.detail ?? JSON.stringify(p)}`);
  }
});

// --- Wire up ---
$("save").addEventListener("click", save);
$("buy").addEventListener("click", () => send("buy"));
$("sell").addEventListener("click", () => send("sell"));
$("close").addEventListener("click", () => send("close"));

document.addEventListener("DOMContentLoaded", load);
