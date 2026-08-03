/*
 * SpirCore-AutoTrader :: Phase 3 - Chrome Extension
 * Content script (runs on TradingView pages).
 *
 * Watches the TradingView alerts log for new entries, parses a simple
 * command grammar out of the alert text, and forwards a Signal to the
 * background service worker (which relays it over WebSocket to the bridge).
 *
 * Alert-text grammar (case-insensitive), examples you set in TradingView:
 *   SPIRCORE BUY
 *   SPIRCORE SELL XAUUSD 0.20
 *   SPIRCORE CLOSE
 *   SPIRCORE DRAW 3358.4 3341.1
 *
 * DOM selectors on TradingView change over time; the ALERT_SELECTORS list
 * is intentionally easy to adjust in one place.
 */

const TRIGGER = "SPIRCORE";

// Candidate containers/rows for the alerts log (best-effort, adjustable).
const ALERT_SELECTORS = [
  '[data-name="alerts-log-item"]',
  '.alert-log-item',
  '[class*="alertLogItem"]',
  '[class*="logItem"]',
];

const seen = new Set(); // de-dupe processed alert texts (within this session)

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------
function parseCommand(text) {
  if (!text) return null;
  const upper = text.toUpperCase();
  const at = upper.indexOf(TRIGGER);
  if (at < 0) return null;

  const tokens = upper.slice(at + TRIGGER.length).trim().split(/\s+/).filter(Boolean);
  if (!tokens.length) return null;

  const action = tokens[0].toLowerCase();
  if (!["buy", "sell", "close", "draw"].includes(action)) return null;

  const sig = { action };

  if (action === "draw") {
    sig.levels = tokens.slice(1).map(Number).filter((n) => !isNaN(n) && n > 0);
    if (!sig.levels.length) return null;
    return sig;
  }

  // buy/sell/close may carry: [SYMBOL] [LOT]
  for (const tok of tokens.slice(1)) {
    const num = Number(tok);
    if (!isNaN(num) && num > 0) sig.lot = num;
    else sig.symbol = tok; // keep original casing not needed; server matches broker symbol
  }
  return sig;
}

function handleText(text) {
  const key = text.trim();
  if (seen.has(key)) return;
  const sig = parseCommand(text);
  if (!sig) return;
  seen.add(key);

  chrome.runtime.sendMessage({ type: "signal", payload: sig }, (res) => {
    console.log("[spircore] relayed", sig, "->", res);
  });
}

// ---------------------------------------------------------------------------
// Observing the alerts log
// ---------------------------------------------------------------------------
function scanNode(node) {
  if (!(node instanceof HTMLElement)) return;
  for (const sel of ALERT_SELECTORS) {
    if (node.matches && node.matches(sel)) { handleText(node.innerText || ""); }
    node.querySelectorAll?.(sel).forEach((el) => handleText(el.innerText || ""));
  }
}

const observer = new MutationObserver((mutations) => {
  for (const m of mutations) {
    m.addedNodes.forEach(scanNode);
  }
});

observer.observe(document.documentElement, { childList: true, subtree: true });

// Also expose a manual hook for testing from the page console:
//   window.__spircore("SPIRCORE BUY XAUUSD 0.10")
window.__spircore = handleText;

console.log("[spircore] content script active on TradingView");
