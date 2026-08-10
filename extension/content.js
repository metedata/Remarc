// content.js — runs in ISOLATED world
// Holds WebSocket connection to Remarc, handles selection enrichment and element grab.

(function () {
  "use strict";

  if (globalThis.__remarcContentScriptLoaded) return;
  globalThis.__remarcContentScriptLoaded = true;

  const REMARC_WS_URL = "ws://127.0.0.1:9274";
  const SELECTION_DEBOUNCE_MS = 200;

  let ws = null;
  let pendingMessages = [];
  let lastActivitySent = 0;
  let grabModeActive = false;
  let highlightOverlay = null;
  let extensionEnabled = true;
  // True when Chrome's Local Network Access policy synchronously blocks the
  // WebSocket to 127.0.0.1 (signature: readyState === CLOSED immediately after
  // construction, without ever entering CONNECTING). Surfaced to the popup so
  // the user gets a targeted "allow loopback" hint instead of a generic error.
  let lnaBlocked = false;
  let reconnectTimer = null;

  // Region select state
  let regionSelectActive = false;
  let regionOverlay = null;
  let regionSelectionDiv = null;
  let regionStart = null;

  // Persistent region highlight state
  let regionHighlightActive = false;

  // Convert a viewport-relative rect to global screen coordinates (Quartz, Y-down).
  // Accounts for vertical chrome (tabs, address bar) and horizontal chrome (e.g. Arc sidebar).
  // Native side converts y from Quartz to AppKit.
  function viewportToScreenRect(x, y, w, h) {
    const chromeY = window.outerHeight - window.innerHeight;
    const chromeX = window.outerWidth - window.innerWidth;
    return {
      x: window.screenX + chromeX + x,
      y: window.screenY + chromeY + y,
      width: w,
      height: h,
    };
  }

  // Shortcut configuration — loaded from chrome.storage.local, synced from app
  let shortcutConfig = {
    "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
    "region-select": { key: "R", modifiers: ["Alt", "Shift"] },
    // HyperFrames quick note — captures only the timeline moment (no DOM target).
    // Debug-only on the Remarc side; the extension sends the message regardless,
    // and the app drops it unless webContextHyperframesEnabled is toggled on.
    "hf-quick-note": { key: "N", modifiers: ["Alt", "Shift"] },
  };

  // Load enabled state and shortcuts
  if (typeof chrome !== "undefined" && chrome.storage) {
    chrome.storage.local.get({ extensionEnabled: true }, (result) => {
      extensionEnabled = result.extensionEnabled;
    });
    chrome.storage.local.get("shortcuts", (result) => {
      if (result.shortcuts) {
        shortcutConfig = result.shortcuts;
      }
    });
    // Consolidated storage change listener — handles both enabled state and shortcuts
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area !== "local") return;
      if (changes.extensionEnabled) {
        extensionEnabled = changes.extensionEnabled.newValue;
      }
      if (changes.shortcuts?.newValue) {
        shortcutConfig = changes.shortcuts.newValue;
      }
    });
  }

  // --- WebSocket Connection ---

  // Fingerprinting the close reason on loopback:
  //   * Successful open: tens of ms.
  //   * ECONNREFUSED (Remarc app not running): near-instant, < ~50ms.
  //   * Chrome Local Network Access block: an async policy check between
  //     ~100ms and a few seconds before the connection is torn down with
  //     close code 1006 and no onopen.
  //   * Chrome TCP/handshake timeout: > 30s.
  // We claim "blocked by Chrome" only inside the LNA window AND when the
  // socket never reached OPEN. Anything else falls back to normal retry, so
  // a false positive on a flaky network self-corrects via the next attempt.
  const LNA_MIN_ELAPSED_MS = 80;
  const LNA_MAX_ELAPSED_MS = 15_000;
  // Re-probe every 30s while blocked. If the user has since granted the
  // permission, this picks it up automatically; if not, the next close
  // re-asserts the blocked state with no UI churn.
  const LNA_REPROBE_INTERVAL_MS = 30_000;

  function connect() {
    if (ws && ws.readyState <= WebSocket.OPEN) return;

    const startedAt = Date.now();
    let sawOpen = false;

    try {
      ws = new WebSocket(REMARC_WS_URL);
    } catch (e) {
      // SecurityError thrown synchronously (HTTPS->ws:// mixed content for
      // non-loopback hosts, or some CSP variants). Same user-facing fix as
      // LNA: allow the site to reach apps on the device.
      markBlocked(`constructor threw ${e?.name || "error"}`);
      scheduleReconnect(LNA_REPROBE_INTERVAL_MS);
      return;
    }

    // Synchronous policy close: some Chrome versions mark the socket CLOSED
    // before the constructor returns. No open/close events fire.
    if (ws.readyState === WebSocket.CLOSED) {
      ws = null;
      markBlocked("synchronous close from constructor");
      scheduleReconnect(LNA_REPROBE_INTERVAL_MS);
      return;
    }

    ws.onopen = () => {
      sawOpen = true;
      lnaBlocked = false;
      notifyBadge(true);
      console.log("[Remarc] Connected.");
      flushPendingMessages();
    };

    ws.onmessage = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === "regionQuery") {
          handleRegionQuery(msg.data);
        } else if (msg.type === "shortcutConfig") {
          shortcutConfig = msg.data;
          chrome.storage.local.set({ shortcuts: msg.data });
        } else if (msg.type === "dismissRegionHighlight") {
          dismissRegionHighlight();
        }
      } catch (e) {
        console.error("[Remarc] Bad message:", e);
      }
    };

    ws.onclose = () => {
      const elapsed = Date.now() - startedAt;
      ws = null;
      notifyBadge(false);
      dismissRegionHighlight();
      if (
        !sawOpen &&
        elapsed > LNA_MIN_ELAPSED_MS &&
        elapsed < LNA_MAX_ELAPSED_MS
      ) {
        markBlocked(`closed after ${elapsed}ms without opening`);
        // Re-probe slowly so we auto-correct if the user grants permission.
        scheduleReconnect(LNA_REPROBE_INTERVAL_MS);
        return;
      }
      lnaBlocked = false;
      scheduleReconnect(3000);
    };

    ws.onerror = () => {
      ws?.close();
    };
  }

  function markBlocked(reason) {
    if (!lnaBlocked) {
      console.warn(
        "[Remarc] This site is blocked from reaching the Remarc app on your " +
          `device (${reason}). To allow it: in Chrome's site permissions, set ` +
          "'Apps on Device' to Allow (in Arc this is called 'Loopback Network'). " +
          "'Local network' is a separate permission and doesn't need to change."
      );
    }
    lnaBlocked = true;
    notifyBadge(false);
  }

  function scheduleReconnect(delay) {
    if (reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  }

  function send(type, data) {
    const payload = JSON.stringify({ type, data });
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(payload);
      return;
    }
    pendingMessages.push(payload);
    if (pendingMessages.length > 50) pendingMessages = pendingMessages.slice(-50);
    connect();
  }

  function flushPendingMessages() {
    if (ws?.readyState !== WebSocket.OPEN || pendingMessages.length === 0) return;
    const messages = pendingMessages;
    pendingMessages = [];
    for (const payload of messages) {
      ws.send(payload);
    }
  }

  function notifyBadge(connected) {
    try {
      chrome.runtime?.sendMessage({ type: "ws-status", connected, lnaBlocked });
    } catch {
      // Extension context may be invalidated
    }
  }

  function sendTabActivity(reason) {
    if (document.visibilityState !== "visible") return;
    const now = Date.now();
    if (now - lastActivitySent < 1000) return;
    lastActivitySent = now;
    send("tabActivity", { reason, pageUrl: window.location.href });
  }

  // --- Context Retrieval (via main-world script) ---

  function getContextForElement(opts) {
    const requestId = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        window.removeEventListener("message", handler);
        resolve(null);
      }, 500);

      function handler(event) {
        if (event.data?.type === "__REMARC_CONTEXT_RESULT__" && event.data.requestId === requestId) {
          clearTimeout(timeout);
          window.removeEventListener("message", handler);
          resolve(event.data.data);
        }
      }

      window.addEventListener("message", handler);
      window.postMessage({ type: "__REMARC_GET_CONTEXT__", requestId, ...opts }, "*");
    });
  }

  async function getContextForSpecificElement(el) {
    const contextId = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    el.setAttribute("data-remarc-context-id", contextId);
    try {
      return await getContextForElement({
        selector: `[data-remarc-context-id="${CSS.escape(contextId)}"]`,
      });
    } finally {
      if (el.getAttribute("data-remarc-context-id") === contextId) {
        el.removeAttribute("data-remarc-context-id");
      }
    }
  }

  /// HyperFrames quick-note bridge fetch. Postmessages MAIN world for the
  /// current __remarcHFContext value with no element target, used by Alt+Shift+N.
  /// Resolves to { hyperframesContext, pageUrl } or null when the page has no
  /// HF bridge / errors / times out.
  function getHFQuickNoteContext() {
    const requestId = crypto.randomUUID?.() || `${Date.now()}-${Math.random()}`;
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        window.removeEventListener("message", handler);
        resolve(null);
      }, 500);

      function handler(event) {
        if (event.data?.type === "__REMARC_HF_CONTEXT_RESULT__" && event.data.requestId === requestId) {
          clearTimeout(timeout);
          window.removeEventListener("message", handler);
          resolve(event.data.data);
        }
      }

      window.addEventListener("message", handler);
      window.postMessage({ type: "__REMARC_GET_HF_CONTEXT__", requestId }, "*");
    });
  }

  async function triggerHFQuickNote() {
    if (!extensionEnabled) return false;
    const result = await getHFQuickNoteContext();
    if (!result || !result.hyperframesContext) {
      // Not an HF page or bridge errored — silently no-op.
      // (Logging would spam every keypress on non-HF tabs.)
      return false;
    }
    send("hfQuickNote", {
      hyperframesContext: result.hyperframesContext,
      pageUrl: result.pageUrl || window.location.href,
    });
    return true;
  }

  // --- Selection Enrichment ---

  let selectionTimer = null;

  function onSelectionChange() {
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(handleSelectionChange, SELECTION_DEBOUNCE_MS);
  }
  document.addEventListener("selectionchange", onSelectionChange);

  async function handleSelectionChange() {
    if (!extensionEnabled) return;
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;

    const context = await getContextForElement({ selection: true });

    if (context) {
      send("selectionContext", context);
    }
  }

  // --- Element Grab Mode ---

  function enterGrabMode() {
    if (!extensionEnabled || grabModeActive) return false;
    dismissRegionHighlight();
    grabModeActive = true;

    highlightOverlay = document.createElement("div");
    highlightOverlay.id = "__remarc-grab-overlay__";
    Object.assign(highlightOverlay.style, {
      position: "fixed",
      pointerEvents: "none",
      border: "2px solid #6366f1",
      borderRadius: "4px",
      backgroundColor: "rgba(99, 102, 241, 0.1)",
      zIndex: "2147483647",
      display: "none",
      transition: "all 0.05s ease-out",
    });
    document.documentElement.appendChild(highlightOverlay);

    document.addEventListener("mousemove", grabMouseMove, true);
    document.addEventListener("click", grabClick, true);
    document.addEventListener("keydown", grabKeyDown, true);
    connect();
    return true;
  }

  function exitGrabMode() {
    grabModeActive = false;
    highlightOverlay?.remove();
    highlightOverlay = null;
    document.removeEventListener("mousemove", grabMouseMove, true);
    document.removeEventListener("click", grabClick, true);
    document.removeEventListener("keydown", grabKeyDown, true);
  }

  function grabMouseMove(e) {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === highlightOverlay) return;

    const rect = el.getBoundingClientRect();
    Object.assign(highlightOverlay.style, {
      display: "block",
      left: rect.left + "px",
      top: rect.top + "px",
      width: rect.width + "px",
      height: rect.height + "px",
    });
  }

  async function grabClick(e) {
    e.preventDefault();
    e.stopPropagation();

    // Capture the element and its bounds at click time (before async work)
    const el = document.elementFromPoint(e.clientX, e.clientY);
    const elRect = el ? el.getBoundingClientRect() : null;

    const context = await getContextForElement({
      x: e.clientX,
      y: e.clientY,
    });

    // regionRect must arrive before elementGrab so the native side has
    // the anchor position before showForWebElement consumes it.
    if (elRect) {
      send("regionRect", viewportToScreenRect(elRect.left, elRect.top, elRect.width, elRect.height));
    }
    // Fall back to a page-URL-only context when main-world.js is unavailable
    // (some sites block MAIN-world content scripts via CSP). Without this,
    // the click is silently swallowed and the comment box never opens.
    send("elementGrab", context || { pageUrl: window.location.href });

    exitGrabMode();
  }

  function grabKeyDown(e) {
    if (e.key === "Escape") {
      exitGrabMode();
    }
  }

  // Listen for commands from popup and keyboard shortcuts
  if (typeof chrome !== "undefined" && chrome.runtime) {
    chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
      switch (msg.type) {
        case "grab-element":
          sendResponse({ ok: enterGrabMode(), connected: ws?.readyState === WebSocket.OPEN });
          return false;
        case "region-select":
          sendResponse({ ok: enterRegionSelectMode(), connected: ws?.readyState === WebSocket.OPEN });
          return false;
        case "hf-quick-note":
          // Fire-and-forget — triggerHFQuickNote is async but the caller
          // (popup or background) doesn't need to wait for the WS round trip.
          triggerHFQuickNote().then((ok) => {
            sendResponse({ ok, connected: ws?.readyState === WebSocket.OPEN });
          });
          return true; // async response

        case "open-settings":
          send("openExtensionSettings", {});
          sendResponse({ ok: true, connected: ws?.readyState === WebSocket.OPEN });
          return false;
        case "get-status":
          sendResponse({
            available: true,
            enabled: extensionEnabled,
            connected: ws?.readyState === WebSocket.OPEN,
            lnaBlocked,
          });
          return false; // synchronous response
        case "retry-connect":
          // Popup nudges us after the user (presumably) flipped a Chrome
          // setting. Clear the cooldown and try again immediately. Don't
          // preemptively clear lnaBlocked - the new attempt will set it
          // correctly: onopen clears, onclose-without-open re-affirms. If we
          // cleared here, the popup's status query could land during the
          // CONNECTING window and report a stale "unblocked" state.
          if (reconnectTimer) {
            clearTimeout(reconnectTimer);
            reconnectTimer = null;
          }
          connect();
          sendResponse({ ok: true });
          return false;
      }
    });
  }

  // --- Multi-Point Region Sampling ---

  function isRemarcElement(el) {
    return el?.id?.startsWith("__remarc") || el?.closest?.("#__remarc-grab-overlay__");
  }

  function rectOverlap(a, b) {
    const left = Math.max(a.left, b.left);
    const top = Math.max(a.top, b.top);
    const right = Math.min(a.right, b.right);
    const bottom = Math.min(a.bottom, b.bottom);
    if (right <= left || bottom <= top) return 0;
    return (right - left) * (bottom - top);
  }

  function elementKey(el) {
    const rect = el.getBoundingClientRect();
    return [
      el.tagName,
      el.id || "",
      typeof el.className === "string" ? el.className : "",
      Math.round(rect.left),
      Math.round(rect.top),
      Math.round(rect.width),
      Math.round(rect.height),
      (el.textContent || "").trim().slice(0, 80),
    ].join("|");
  }

  function isMeaningfulRegionElement(el) {
    if (!(el instanceof HTMLElement) || isRemarcElement(el)) return false;

    const rect = el.getBoundingClientRect();
    if (rect.width < 8 || rect.height < 8) return false;
    if (rect.width > window.innerWidth * 0.95 && rect.height > window.innerHeight * 0.8) return false;

    const tag = el.tagName;
    const meaningfulTags = new Set([
      "BUTTON", "A", "INPUT", "TEXTAREA", "SELECT", "IMG", "VIDEO", "CANVAS",
      "P", "H1", "H2", "H3", "H4", "H5", "H6", "LI", "LABEL", "TD", "TH",
      "SECTION", "ARTICLE", "ASIDE", "NAV", "HEADER", "FOOTER", "MAIN",
    ]);
    if (meaningfulTags.has(tag)) return true;

    const role = el.getAttribute("role");
    if (role && ["button", "link", "menuitem", "tab", "checkbox", "radio"].includes(role)) return true;
    if (el.hasAttribute("data-testid") || el.hasAttribute("data-test") || el.hasAttribute("data-cy")) return true;

    if (tag === "DIV" || tag === "SPAN") {
      const text = el.textContent?.trim() || "";
      const hasNestedMeaningful = el.querySelector("button, a, input, textarea, select, img, p, h1, h2, h3, h4, h5, h6, li, label");
      const isInteractive = el.onclick || el.getAttribute("tabindex") || role;
      return (isInteractive || (text.length > 0 && text.length <= 140)) && !hasNestedMeaningful;
    }

    return false;
  }

  async function sampleElementsInRect(x, y, w, h, limit = 20) {
    const selectionRect = { left: x, top: y, right: x + w, bottom: y + h };
    const candidates = new Map();
    const points = [
      [x, y],
      [x + w, y],
      [x, y + h],
      [x + w, y + h],
      [x + w / 2, y + h / 2],
      [x + w / 2, y],
      [x + w / 2, y + h],
      [x, y + h / 2],
      [x + w, y + h / 2],
    ];

    for (const [px, py] of points) {
      const stack = document.elementsFromPoint(
        Math.min(Math.max(px, 0), window.innerWidth - 1),
        Math.min(Math.max(py, 0), window.innerHeight - 1)
      );
      for (const el of stack) {
        if (el instanceof HTMLElement) candidates.set(elementKey(el), el);
      }
    }

    const broadSelector = [
      "button", "a", "input", "textarea", "select", "img", "video", "canvas",
      "p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "label", "td", "th",
      "section", "article", "aside", "nav", "header", "footer", "main",
      "[role='button']", "[role='link']", "[role='menuitem']", "[role='tab']",
      "[data-testid]", "[data-test]", "[data-cy]",
    ].join(",");

    for (const el of document.querySelectorAll(broadSelector)) {
      if (el instanceof HTMLElement) candidates.set(elementKey(el), el);
    }

    const matches = Array.from(candidates.values())
      .map((el) => {
        const rect = el.getBoundingClientRect();
        const overlap = rectOverlap(rect, selectionRect);
        const area = Math.max(1, rect.width * rect.height);
        const centerX = rect.left + rect.width / 2;
        const centerY = rect.top + rect.height / 2;
        const centerInside =
          centerX >= selectionRect.left &&
          centerX <= selectionRect.right &&
          centerY >= selectionRect.top &&
          centerY <= selectionRect.bottom;
        return { el, rect, overlap, overlapRatio: overlap / area, centerInside };
      })
      .filter(({ el, overlap, overlapRatio, centerInside }) =>
        isMeaningfulRegionElement(el) && (centerInside || overlapRatio > 0.25 || overlap > 400)
      );

    const leafMatches = matches.filter(({ el }) =>
      !matches.some(({ el: other }) => other !== el && el.contains(other))
    );
    const finalMatches = (leafMatches.length > 0 ? leafMatches : matches)
      .sort((a, b) => {
        if (b.overlap !== a.overlap) return b.overlap - a.overlap;
        return (a.rect.width * a.rect.height) - (b.rect.width * b.rect.height);
      })
      .slice(0, limit);

    const results = [];
    const seenContexts = new Set();
    for (const { el } of finalMatches) {
      const ctx = await getContextForSpecificElement(el);
      if (!ctx) continue;
      const key = [
        ctx.pageUrl || "",
        ctx.selector || "",
        ctx.elementName || "",
        ctx.boundingBox ? `${ctx.boundingBox.x},${ctx.boundingBox.y},${ctx.boundingBox.width},${ctx.boundingBox.height}` : "",
      ].join("|");
      if (seenContexts.has(key)) continue;
      seenContexts.add(key);
      results.push(ctx);
    }
    return results;
  }

  // --- Region Select Mode ---

  function enterRegionSelectMode() {
    if (!extensionEnabled || regionSelectActive) return false;
    dismissRegionHighlight();
    regionSelectActive = true;

    regionOverlay = document.createElement("div");
    Object.assign(regionOverlay.style, {
      position: "fixed",
      inset: "0",
      zIndex: "2147483647",
      cursor: "crosshair",
      background: "transparent",
    });
    document.documentElement.appendChild(regionOverlay);

    regionOverlay.addEventListener("mousedown", regionMouseDown);
    document.addEventListener("keydown", regionKeyDown, true);
    connect();
    return true;
  }

  function exitRegionSelectMode() {
    regionSelectActive = false;
    regionSelectionDiv?.remove();
    regionSelectionDiv = null;
    regionOverlay?.remove();
    regionOverlay = null;
    regionStart = null;
    document.removeEventListener("keydown", regionKeyDown, true);
  }

  function regionMouseDown(e) {
    e.preventDefault();
    regionStart = { x: e.clientX, y: e.clientY };

    regionSelectionDiv = document.createElement("div");
    Object.assign(regionSelectionDiv.style, {
      position: "fixed",
      border: "1.5px solid white",
      borderRadius: "4px",
      boxShadow: "0 0 0 9999px rgba(0,0,0,0.4)",
      pointerEvents: "none",
      zIndex: "2147483647",
      left: e.clientX + "px",
      top: e.clientY + "px",
      width: "0px",
      height: "0px",
    });
    document.documentElement.appendChild(regionSelectionDiv);

    regionOverlay.addEventListener("mousemove", regionMouseMove);
    regionOverlay.addEventListener("mouseup", regionMouseUp);
    regionOverlay.addEventListener("mouseleave", regionMouseLeave);
  }

  function regionMouseMove(e) {
    if (!regionStart || !regionSelectionDiv) return;

    const x = Math.min(e.clientX, regionStart.x);
    const y = Math.min(e.clientY, regionStart.y);
    const w = Math.abs(e.clientX - regionStart.x);
    const h = Math.abs(e.clientY - regionStart.y);

    Object.assign(regionSelectionDiv.style, {
      left: x + "px",
      top: y + "px",
      width: w + "px",
      height: h + "px",
    });
  }

  function regionMouseUp(e) {
    finalizeRegionSelection(e.clientX, e.clientY);
  }

  function regionMouseLeave(e) {
    if (!regionStart) return;
    // Clamp to viewport so the selection rect stays within bounds
    const cx = Math.min(Math.max(e.clientX, 0), window.innerWidth);
    const cy = Math.min(Math.max(e.clientY, 0), window.innerHeight);
    finalizeRegionSelection(cx, cy);
  }

  async function finalizeRegionSelection(clientX, clientY) {
    regionOverlay?.removeEventListener("mousemove", regionMouseMove);
    regionOverlay?.removeEventListener("mouseup", regionMouseUp);
    regionOverlay?.removeEventListener("mouseleave", regionMouseLeave);

    if (!regionStart) {
      exitRegionSelectMode();
      return;
    }

    const x = Math.min(clientX, regionStart.x);
    const y = Math.min(clientY, regionStart.y);
    const w = Math.abs(clientX - regionStart.x);
    const h = Math.abs(clientY - regionStart.y);

    // Tiny drags — full cleanup, no persistent highlight
    if (w < 10 || h < 10) {
      exitRegionSelectMode();
      return;
    }

    // Update selection div to final clamped size
    if (regionSelectionDiv) {
      Object.assign(regionSelectionDiv.style, {
        left: x + "px",
        top: y + "px",
        width: w + "px",
        height: h + "px",
      });
    }

    // 1. Hide the selection div so elementsFromPoint hits real page content
    if (regionSelectionDiv) regionSelectionDiv.style.display = "none";

    // 2. Remove interactive overlay (also blocks elementsFromPoint)
    regionOverlay?.remove();
    regionOverlay = null;

    // 3. Sample elements while overlays are hidden
    let elements = await sampleElementsInRect(x, y, w, h);

    // Fallback: if grid sampling found nothing, try the element at the center
    if (elements.length === 0) {
      const centerCtx = await getContextForElement({
        x: x + w / 2,
        y: y + h / 2,
      });
      if (centerCtx) elements = [centerCtx];
    }

    // 4. Re-show selection div and enter persistent highlight mode
    if (regionSelectionDiv) regionSelectionDiv.style.display = "";
    enterPersistentHighlight();

    // 5. Send region screen rect (for panel positioning), then context to app.
    send("regionRect", viewportToScreenRect(x, y, w, h));

    if (elements.length > 0) {
      send("elementGrab", elements[0]);
      if (elements.length > 1) {
        send("regionContext", { elements });
      }
    } else {
      // No identifiable elements in region; send bare page URL so the panel still opens
      send("elementGrab", { pageUrl: window.location.href });
    }
  }

  function regionKeyDown(e) {
    if (e.key === "Escape") {
      exitRegionSelectMode();
    }
  }

  // --- Persistent Region Highlight ---

  function enterPersistentHighlight() {
    regionSelectActive = false;
    regionStart = null;

    // Remove the interactive overlay (clicks pass through to page/app)
    regionOverlay?.remove();
    regionOverlay = null;

    // Keep regionSelectionDiv visible (already has pointerEvents: "none")
    regionHighlightActive = true;

    // Replace region keydown with highlight keydown (Escape dismisses)
    document.removeEventListener("keydown", regionKeyDown, true);
    document.addEventListener("keydown", highlightKeyDown, true);
  }

  function dismissRegionHighlight() {
    if (!regionHighlightActive) return;
    regionHighlightActive = false;

    regionSelectionDiv?.remove();
    regionSelectionDiv = null;

    document.removeEventListener("keydown", highlightKeyDown, true);
  }

  function highlightKeyDown(e) {
    if (e.key === "Escape") {
      dismissRegionHighlight();
      send("regionHighlightDismissed", {});
    }
  }

  // --- Region Query (screenshot enrichment) ---

  async function handleRegionQuery(data) {
    if (document.visibilityState !== "visible") return;

    const { screenX, screenY, width, height, queryId, purpose, maxElements } = data;

    const chromeX = window.outerWidth - window.innerWidth;
    const chromeY = window.outerHeight - window.innerHeight;
    const vpX = screenX - window.screenX - chromeX;
    const vpY = screenY - window.screenY - chromeY;

    if (
      vpX + width < 0 ||
      vpY + height < 0 ||
      vpX > window.innerWidth ||
      vpY > window.innerHeight
    ) {
      return;
    }

    const queryX = Math.max(0, vpX);
    const queryY = Math.max(0, vpY);
    const queryRight = Math.min(window.innerWidth, vpX + width);
    const queryBottom = Math.min(window.innerHeight, vpY + height);

    const limit = Math.max(1, Math.min(maxElements || 20, 20));
    let elements = [];
    if (purpose === "textSelection") {
      const selectionContext = await getContextForElement({ selection: true });
      if (selectionContext?.selectedText) elements = [selectionContext];
    }

    if (elements.length === 0 && limit === 1) {
      const context = await getContextForElement({
        x: queryX + (queryRight - queryX) / 2,
        y: queryY + (queryBottom - queryY) / 2,
      });
      elements = context ? [context] : [];
    } else if (elements.length === 0) {
      elements = await sampleElementsInRect(queryX, queryY, queryRight - queryX, queryBottom - queryY, limit);
    }

    send("regionContext", {
      queryId,
      purpose,
      elements: elements.length > 0 ? elements : [{ pageUrl: window.location.href }],
    });
  }

  // Map config key name (e.g. "G", "1", "F2") to KeyboardEvent.code value.
  // event.code represents the physical key and is unaffected by Option/Alt remapping.
  function configKeyToCode(key) {
    if (/^[A-Z]$/i.test(key)) return "Key" + key.toUpperCase();
    if (/^[0-9]$/.test(key)) return "Digit" + key;
    if (/^F\d+$/.test(key)) return key; // F1–F12
    return null;
  }

  // Keyboard shortcut listener — capture phase, registered at document_start
  function onShortcutKeydown(event) {
    if (!extensionEnabled) return;

    // Skip if typing in form fields
    const tag = event.target.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || event.target.isContentEditable) {
      return;
    }

    for (const [command, config] of Object.entries(shortcutConfig)) {
      // Use event.code (physical key) instead of event.key because
      // macOS Option key remaps event.key to special characters (e.g. Alt+G → "©")
      const code = configKeyToCode(config.key);
      const keyMatch = code ? event.code === code : event.key.toUpperCase() === config.key.toUpperCase();
      const altMatch = event.altKey === config.modifiers.includes("Alt");
      const shiftMatch = event.shiftKey === config.modifiers.includes("Shift");
      const ctrlMatch = event.ctrlKey === config.modifiers.includes("Control");
      const metaMatch = event.metaKey === config.modifiers.includes("Meta");

      if (keyMatch && altMatch && shiftMatch && ctrlMatch && metaMatch) {
        event.preventDefault();
        event.stopPropagation();

        if (command === "grab-element") {
          enterGrabMode();
        } else if (command === "region-select") {
          enterRegionSelectMode();
        } else if (command === "hf-quick-note") {
          triggerHFQuickNote();
        }
        return;
      }
    }
  }
  document.addEventListener("keydown", onShortcutKeydown, true);
  window.addEventListener("focus", () => sendTabActivity("focus"));
  document.addEventListener("visibilitychange", () => sendTabActivity("visibility"));
  document.addEventListener("mousedown", () => sendTabActivity("mousedown"), true);

  // --- Init ---
  connect();
  setTimeout(() => sendTabActivity("init"), 0);
})();
