/*
 * SpirCore-AutoTrader :: Phase 3 - Chrome Extension
 * Background service worker.
 *
 * Owns the persistent WebSocket to the local Python bridge (ws://host:port/ws)
 * and relays Signal messages from the content script / popup to it.
 *
 * MV3 service workers can be suspended; we keep the socket resilient with
 * automatic reconnect + a lightweight keep-alive ping.
 */

const DEFAULTS = {
  host: "127.0.0.1",
  port: 8000,
  token: "change-me",
  symbol: "XAUUSD",
  lot: 0.1,
};

let ws = null;
let connected = false;
let reconnectDelay = 1000; // ms, grows on failure up to a cap
let keepAliveTimer = null;
let cfg = { ...DEFAULTS };

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
async function loadConfig() {
  const stored = await chrome.storage.local.get(Object.keys(DEFAULTS));
  cfg = { ...DEFAULTS, ...stored };
  return cfg;
}

// ---------------------------------------------------------------------------
// WebSocket lifecycle
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
// Sending signals
// ---------------------------------------------------------------------------
function sendSignal(sig) {
  // Always attach the shared secret + default symbol/lot if missing.
  const payload = {
    secret: cfg.token,
    symbol: sig.symbol || cfg.symbol,
    ...sig,
  };
  if ((payload.action === "buy" || payload.action === "sell") && payload.lot == null) {
    payload.lot = Number(cfg.lot);
  }

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
    return { ok: true, detail: "sent" };
  }
  // Not connected -> try to (re)connect; caller sees the failure.
  connect();
  return { ok: false, detail: "not connected" };
}

function broadcastStatus() {
  chrome.runtime
    .sendMessage({ type: "status", connected, url: wsUrl() })
    .catch(() => {});
}

// ---------------------------------------------------------------------------
// Message routing (content script + popup)
// ---------------------------------------------------------------------------
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    switch (msg.type) {
      case "signal": {
        const res = sendSignal(msg.payload || {});
        sendResponse(res);
        break;
      }
      case "getStatus":
        sendResponse({ connected, url: wsUrl(), cfg });
        break;
      case "reconnect":
        await loadConfig();
        connect();
        sendResponse({ ok: true });
        break;
      case "configUpdated":
        await loadConfig();
        connect();
        sendResponse({ ok: true });
        break;
      default:
        sendResponse({ ok: false, detail: "unknown message" });
    }
  })();
  return true; // async response
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
chrome.runtime.onInstalled.addListener(async () => { await loadConfig(); connect(); });
chrome.runtime.onStartup.addListener(async () => { await loadConfig(); connect(); });
(async () => { await loadConfig(); connect(); })();
