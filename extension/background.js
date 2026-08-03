/*
 * SpirCore-AutoTrader :: Chrome Extension
 * Background service worker.
 *
 * Routes trading signals to one of two execution backends:
 *
 *   "bridge" -> persistent WebSocket to the local Python bridge, which
 *               drives the MT5 DESKTOP terminal (official MetaTrader5 lib).
 *   "web"    -> direct UI automation of the MT5 WEB terminal in an open
 *               browser tab (no desktop app / no Python bridge needed).
 *   "auto"   -> prefer the bridge when connected, else fall back to web.
 *
 * MV3 service workers can be suspended; the socket is kept resilient with
 * automatic reconnect + a lightweight keep-alive ping.
 */

const DEFAULTS = {
  host: "127.0.0.1",
  port: 8000,
  token: "change-me",
  symbol: "XAUUSD",
  lot: 0.1,
  mode: "auto", // "bridge" | "web" | "auto"
};

let ws = null;
let connected = false;
let reconnectDelay = 1000; // ms, grows on failure up to a cap
let keepAliveTimer = null;
let cfg = { ...DEFAULTS };

// Tabs that have an MT5 Web content script registered (tabId -> true).
const mt5WebTabs = new Set();

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
async function loadConfig() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  cfg = { ...DEFAULTS, ...stored };
  return cfg;
}

// ---------------------------------------------------------------------------
// WebSocket lifecycle (bridge backend)
// ---------------------------------------------------------------------------
function wsUrl() {
  return `ws://${cfg.host}:${cfg.port}/ws`;
}

function connect() {
  cleanup();
  try {
    ws = new WebSocket(wsUrl());
  } catch (e) {
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    connected = true;
    reconnectDelay = 1000;
    broadcastStatus();
    startKeepAlive();
    console.log("[spircore] WS connected:", wsUrl());
  };

  ws.onmessage = (ev) => {
    // Bridge replies with a Result JSON; forward it to any open popup.
    let data = ev.data;
    try { data = JSON.parse(ev.data); } catch (_) {}
    chrome.runtime.sendMessage({ type: "wsReply", payload: data }).catch(() => {});
  };

  ws.onclose = () => {
    connected = false;
    broadcastStatus();
    scheduleReconnect();
  };

  ws.onerror = () => {
    // onclose will follow and handle reconnect.
    if (ws && ws.readyState !== WebSocket.OPEN) connected = false;
  };
}

function cleanup() {
  if (keepAliveTimer) { clearInterval(keepAliveTimer); keepAliveTimer = null; }
  if (ws) {
    ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
    try { ws.close(); } catch (_) {}
    ws = null;
  }
}

function scheduleReconnect() {
  reconnectDelay = Math.min(reconnectDelay * 2, 15000);
  setTimeout(connect, reconnectDelay);
}

function startKeepAlive() {
  if (keepAliveTimer) clearInterval(keepAliveTimer);
  // A tiny periodic no-op keeps the socket (and the worker) warm.
  keepAliveTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try { ws.send(JSON.stringify({ secret: cfg.token, action: "ping" })); } catch (_) {}
    }
  }, 20000);
}

// ---------------------------------------------------------------------------
// Backend: bridge (WebSocket -> Python -> desktop MT5)
// ---------------------------------------------------------------------------
function sendViaBridge(payload) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
    return { ok: true, detail: "sent via bridge", backend: "bridge" };
  }
  connect(); // not connected -> kick a reconnect; caller sees the failure
  return { ok: false, detail: "bridge not connected", backend: "bridge" };
}

// ---------------------------------------------------------------------------
// Backend: web (UI automation of the MT5 Web terminal tab)
// ---------------------------------------------------------------------------
async function pickMt5WebTab() {
  // Prefer a live, registered tab; drop any that no longer exist.
  for (const tabId of [...mt5WebTabs]) {
    try {
      const tab = await chrome.tabs.get(tabId);
      if (tab) return tabId;
    } catch (_) {
      mt5WebTabs.delete(tabId);
    }
  }
  return null;
}

async function sendViaWeb(payload) {
  const tabId = await pickMt5WebTab();
  if (tabId == null) {
    return { ok: false, detail: "no MT5 Web terminal tab open", backend: "web" };
  }
  try {
    const res = await chrome.tabs.sendMessage(tabId, {
      type: "mt5web-execute",
      payload,
    });
    return { ...(res || { ok: false, detail: "no response" }), backend: "web" };
  } catch (e) {
    return { ok: false, detail: `web tab error: ${e.message}`, backend: "web" };
  }
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------
async function routeSignal(sig) {
  // Always attach the shared secret + default symbol/lot if missing.
  const payload = {
    secret: cfg.token,
    symbol: sig.symbol || cfg.symbol,
    ...sig,
  };
  if ((payload.action === "buy" || payload.action === "sell") && payload.lot == null) {
    payload.lot = Number(cfg.lot);
  }

  const mode = cfg.mode || "auto";

  if (mode === "bridge") return sendViaBridge(payload);
  if (mode === "web") return await sendViaWeb(payload);

  // auto: bridge first, fall back to web.
  if (ws && ws.readyState === WebSocket.OPEN) return sendViaBridge(payload);
  return await sendViaWeb(payload);
}

// Send a control action to the bridge's REST /control endpoint.
async function sendControl(payload) {
  const url = `http://${cfg.host}:${cfg.port}/control`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ secret: cfg.token, ...payload }),
    });
    const j = await res.json().catch(() => ({}));
    return { ok: res.ok, detail: j.detail || `HTTP ${res.status}` };
  } catch (e) {
    return { ok: false, detail: `bridge unreachable: ${e.message}` };
  }
}

function broadcastStatus() {
  chrome.runtime
    .sendMessage({
      type: "status",
      connected,
      url: wsUrl(),
      mode: cfg.mode,
      webTabs: mt5WebTabs.size,
    })
    .catch(() => {});
}

// ---------------------------------------------------------------------------
// Message routing (content scripts + popup)
// ---------------------------------------------------------------------------
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  (async () => {
    switch (msg.type) {
      case "signal": {
        const res = await routeSignal(msg.payload || {});
        sendResponse(res);
        break;
      }
      case "registerMt5Web": {
        // The MT5 Web content script announces its tab so we can target it.
        if (sender.tab && sender.tab.id != null) {
          mt5WebTabs.add(sender.tab.id);
          broadcastStatus();
        }
        sendResponse({ ok: true });
        break;
      }
      case "control": {
        // Relay a control action (e.g. strategy/mode select) to the bridge.
        const res = await sendControl(msg.payload || {});
        sendResponse(res);
        break;
      }
      case "getStatus":
        sendResponse({
          connected,
          url: wsUrl(),
          cfg,
          mode: cfg.mode,
          webTabs: mt5WebTabs.size,
        });
        break;
      case "reconnect":
        await loadConfig();
        connect();
        sendResponse({ ok: true });
        break;
      case "configUpdated":
        await loadConfig();
        connect();
        broadcastStatus();
        sendResponse({ ok: true });
        break;
      default:
        sendResponse({ ok: false, detail: "unknown message" });
    }
  })();
  return true; // async response
});

// Forget tabs that close.
chrome.tabs.onRemoved.addListener((tabId) => {
  if (mt5WebTabs.delete(tabId)) broadcastStatus();
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
chrome.runtime.onInstalled.addListener(async () => { await loadConfig(); connect(); });
chrome.runtime.onStartup.addListener(async () => { await loadConfig(); connect(); });
(async () => { await loadConfig(); connect(); })();
