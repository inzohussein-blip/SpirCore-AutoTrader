/*
 * SpirCore-AutoTrader :: Phase 3 - Chrome Extension
 * Popup UI logic: config editing + manual signal buttons + live status.
 */

const $ = (id) => document.getElementById(id);
const FIELDS = ["host", "port", "token", "symbol", "lot", "mode"];

// Status reflects the ACTIVE backend for the current mode:
//   bridge/auto -> WebSocket connected?   web -> an MT5 Web tab open?
function setStatus(st) {
  const mode = st.mode || "auto";
  let online, label;
  if (mode === "web") {
    online = (st.webTabs || 0) > 0;
    label = online ? "web ready" : "no web tab";
  } else if (mode === "bridge") {
    online = !!st.connected;
    label = online ? "bridge on" : "bridge off";
  } else {
    online = !!st.connected || (st.webTabs || 0) > 0;
    label = st.connected ? "bridge on" : (st.webTabs ? "web ready" : "offline");
  }
  const el = $("status");
  el.textContent = label;
  el.className = "status " + (online ? "on" : "off");
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
  $("mode").value = stored.mode ?? "auto";

  const sel = await chrome.storage.local.get(["webSelectors"]);
  $("webSelectors").value = sel.webSelectors ? JSON.stringify(sel.webSelectors) : "";

  chrome.runtime.sendMessage({ type: "getStatus" }, (res) => {
    if (res) setStatus(res);
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
    mode: $("mode").value || "auto",
  };
  // Parse the optional custom-selectors JSON; store separately (read by
  // mt5web.js). Invalid JSON is reported and the field is left unchanged.
  const raw = $("webSelectors").value.trim();
  if (raw) {
    try {
      await chrome.storage.local.set({ webSelectors: JSON.parse(raw) });
    } catch (e) {
      log("invalid selectors JSON — not saved");
      return;
    }
  } else {
    await chrome.storage.local.remove("webSelectors");
  }

  await chrome.storage.local.set(cfg);
  chrome.runtime.sendMessage({ type: "configUpdated" }, () => log("saved, reconnecting…"));
}

// --- Send a manual signal ---
function send(action) {
  chrome.runtime.sendMessage(
    { type: "signal", payload: { action } },
    (res) => log(res ? `${action} [${res.backend || "?"}]: ${res.detail}` : `${action}: no response`)
  );
}

// --- Live updates pushed by the worker ---
chrome.runtime.onMessage.addListener((msg) => {
  if (msg.type === "status") setStatus(msg);
  if (msg.type === "wsReply" && msg.payload) {
    const p = msg.payload;
    log(`${p.action ?? "reply"}: ${p.detail ?? JSON.stringify(p)}`);
  }
});

// --- Wire up ---
$("save").addEventListener("click", save);
$("mode").addEventListener("change", save);
$("buy").addEventListener("click", () => send("buy"));
$("sell").addEventListener("click", () => send("sell"));
$("close").addEventListener("click", () => send("close"));
$("dashboard").addEventListener("click", () => {
  const host = $("host").value.trim() || "127.0.0.1";
  const port = Number($("port").value) || 8000;
  chrome.tabs.create({ url: `http://${host}:${port}/dashboard` });
});

document.addEventListener("DOMContentLoaded", load);
