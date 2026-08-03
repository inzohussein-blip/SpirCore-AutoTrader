/*
 * SpirCore-AutoTrader :: Chrome Extension
 * MT5 Web Terminal automation content script.
 *
 * Runs on the MetaTrader 5 WEB terminal (trade.mql5.com / web.metatrader5.com
 * and broker white-labels). Lets the extension place trades by driving the
 * terminal's own UI -- NO desktop MT5 app and NO Python bridge required.
 *
 * How it works
 *   1. Registers its tab with the background worker.
 *   2. On a "mt5web-execute" message it locates the One-Click-Trading panel
 *      (Buy / Sell buttons + volume field), sets the volume, and clicks.
 *
 * IMPORTANT: the MT5 Web DOM varies by version and broker, so selectors are
 * gathered in SELECTORS below and are meant to be tuned in one place. Open
 * the terminal's "One Click Trading" panel for the most reliable automation.
 *
 * Manual test from the terminal's page console:
 *   window.__spircoreWeb("buy", 0.10)
 */

(function () {
  "use strict";

  // --- Adjustable selectors (best-effort; edit to match your terminal) -----
  // Users can ALSO add broker-specific selectors from the popup ("Custom
  // selectors" JSON); those are merged ahead of these defaults at runtime.
  const SELECTORS = {
    // The volume/lots input in the one-click panel or order dialog.
    volume: [
      'input[title*="Volume" i]',
      'input[aria-label*="Volume" i]',
      'input[name*="volume" i]',
      ".oct-volume input",
      '.one-click input[type="text"]',
    ],
    // Buy button.
    buy: [
      '[title*="Buy" i]',
      '[aria-label*="Buy" i]',
      "button.buy",
      ".oct-buy",
      ".one-click-buy",
    ],
    // Sell button.
    sell: [
      '[title*="Sell" i]',
      '[aria-label*="Sell" i]',
      "button.sell",
      ".oct-sell",
      ".one-click-sell",
    ],
    // "Close all" / positions close control (best-effort).
    closeAll: [
      '[title*="Close" i][title*="all" i]',
      ".close-all",
    ],
  };

  // Merge user-supplied selectors (from popup) ahead of the defaults so a
  // broker-specific tweak wins without editing this file.
  chrome.storage.local.get(["webSelectors"]).then((res) => {
    const custom = res.webSelectors;
    if (!custom || typeof custom !== "object") return;
    for (const key of Object.keys(SELECTORS)) {
      if (Array.isArray(custom[key]) && custom[key].length) {
        SELECTORS[key] = [...custom[key], ...SELECTORS[key]];
      }
    }
    console.log("[spircore] custom MT5 Web selectors merged");
  }).catch(() => {});

  // -------------------------------------------------------------------------
  function findFirst(selList) {
    for (const sel of selList) {
      const els = document.querySelectorAll(sel);
      for (const el of els) {
        if (isVisible(el)) return el;
      }
    }
    return null;
  }

  function isVisible(el) {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 &&
           style.visibility !== "hidden" && style.display !== "none";
  }

  // Set an input's value in a React/Vue-friendly way and fire events.
  function setInputValue(input, value) {
    const proto = Object.getPrototypeOf(input);
    const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    if (setter) setter.call(input, String(value));
    else input.value = String(value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function clickEl(el) {
    // A full pointer sequence is more reliable than a bare .click() in canvas
    // -adjacent UIs.
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
    }
  }

  // -------------------------------------------------------------------------
  function execute(payload) {
    const action = payload.action;

    if (action === "close") {
      const closeBtn = findFirst(SELECTORS.closeAll);
      if (!closeBtn) return { ok: false, detail: "close-all control not found" };
      clickEl(closeBtn);
      return { ok: true, detail: "close-all clicked (verify in terminal)" };
    }

    if (action !== "buy" && action !== "sell") {
      return { ok: false, detail: `web backend does not handle '${action}'` };
    }

    // Set volume first if we can find the field.
    if (payload.lot != null) {
      const vol = findFirst(SELECTORS.volume);
      if (vol) setInputValue(vol, payload.lot);
    }

    const btn = findFirst(action === "buy" ? SELECTORS.buy : SELECTORS.sell);
    if (!btn) {
      return {
        ok: false,
        detail: `${action} button not found -- open the One-Click Trading panel`,
      };
    }
    clickEl(btn);
    return { ok: true, detail: `${action} clicked on MT5 Web (verify fill)` };
  }

  // --- Message handling -----------------------------------------------------
  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg.type === "mt5web-execute") {
      try {
        sendResponse(execute(msg.payload || {}));
      } catch (e) {
        sendResponse({ ok: false, detail: `web exec error: ${e.message}` });
      }
    }
    return true;
  });

  // Register this tab (and re-register periodically, since the worker may
  // restart and forget us).
  function register() {
    chrome.runtime.sendMessage({ type: "registerMt5Web" }).catch(() => {});
  }
  register();
  setInterval(register, 30000);

  // Manual test hook.
  window.__spircoreWeb = (action, lot) => execute({ action, lot });

  console.log("[spircore] MT5 Web automation active");
})();
