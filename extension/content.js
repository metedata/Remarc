// content.js — runs in ISOLATED world
// Relays page context through the extension worker and handles page capture UI.

(function () {
  "use strict";

  const CONTENT_SCRIPT_VERSION = "background-bridge-v1";
  if (globalThis.__remarcContentScriptVersion === CONTENT_SCRIPT_VERSION) return;
  if (
    globalThis.__remarcContentScriptLoaded &&
    typeof globalThis.__remarcContentScriptTeardown !== "function"
  ) {
    // Versions before the background bridge cannot tear down their closure-owned
    // listeners. Those tabs require the one-time reload documented for this update.
    return;
  }
  try {
    globalThis.__remarcContentScriptTeardown?.();
  } catch {
    // A stale content-script generation must not prevent the replacement loading.
  }
  globalThis.__remarcContentScriptLoaded = true;
  globalThis.__remarcContentScriptVersion = CONTENT_SCRIPT_VERSION;

  const SELECTION_DEBOUNCE_MS = 200;
  const MAX_PENDING_MESSAGES = 50;

  let pendingMessages = [];
  let sendInFlight = false;
  let bridgeConnected = false;
  let bridgeInstanceId = null;
  let bridgeStateEpoch = -1;
  let bridgeNudgeInFlight = false;
  let lastActivitySent = 0;
  let grabModeActive = false;
  let highlightOverlay = null;
  // Fail closed until persisted Pause state has loaded. Capture listeners are
  // registered at document_start, so an optimistic default could leak a click
  // or selection during the storage callback window.
  let extensionEnabled = false;
  let captureGeneration = 0;
  let isTornDown = false;
  let selectionTimer = null;
  let initActivityTimer = null;

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
  const DEFAULT_SHORTCUT_CONFIG = {
    "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
    "region-select": { key: "R", modifiers: ["Alt", "Shift"] },
    // HyperFrames quick note — captures only the timeline moment (no DOM target).
    // Debug-only on the Remarc side; the extension sends the message regardless,
    // and the app drops it unless webContextHyperframesEnabled is toggled on.
    "hf-quick-note": { key: "N", modifiers: ["Alt", "Shift"] },
  };
  let shortcutConfig = { ...DEFAULT_SHORTCUT_CONFIG };

  // Load enabled state and shortcuts
  if (typeof chrome !== "undefined" && chrome.storage) {
    chrome.storage.local.get({ extensionEnabled: true }, (result) => {
      if (isTornDown) return;
      extensionEnabled = result.extensionEnabled !== false;
      if (!extensionEnabled) cancelCaptureInteractions();
    });
    chrome.storage.local.get("shortcuts", (result) => {
      if (isTornDown) return;
      if (result.shortcuts) {
        shortcutConfig = { ...DEFAULT_SHORTCUT_CONFIG, ...result.shortcuts };
      }
    });
    chrome.storage.onChanged.addListener(handleStorageChanged);
  }

  // --- Native bridge messaging ---

  function handleStorageChanged(changes, area) {
    if (area !== "local" || isTornDown) return;
    if (changes.extensionEnabled) {
      extensionEnabled = changes.extensionEnabled.newValue;
      if (!extensionEnabled) cancelCaptureInteractions();
    }
    if (changes.shortcuts?.newValue) {
      shortcutConfig = { ...DEFAULT_SHORTCUT_CONFIG, ...changes.shortcuts.newValue };
    }
  }

  function cancelCaptureInteractions() {
    captureGeneration += 1;
    clearTimeout(selectionTimer);
    selectionTimer = null;
    // Pausing is a privacy boundary: captures that have not crossed the
    // worker boundary must not replay after Resume or a later app launch.
    pendingMessages = [];
    exitGrabMode();
    exitRegionSelectMode();
    dismissRegionHighlight();
  }

  function sendRuntimeMessage(message, callback = () => {}) {
    if (isTornDown) {
      callback(null);
      return;
    }
    try {
      chrome.runtime.sendMessage(message, (response) => {
        if (isTornDown || chrome.runtime.lastError) {
          callback(null);
          return;
        }
        callback(response ?? null);
      });
    } catch {
      callback(null);
    }
  }

  function send(type, data) {
    const envelope = { type, data };

    // Activity is useful to the worker for routing and reconnect wakeups, but it
    // is stale by definition once disconnected and must never enter the FIFO.
    if (type === "tabActivity") {
      sendRuntimeMessage({ type: "native-message", envelope });
      return;
    }

    pendingMessages.push(envelope);
    if (pendingMessages.length > MAX_PENDING_MESSAGES) {
      // The first entry may already be crossing the extension boundary. Keep
      // it stable and evict the oldest item that has not started yet.
      pendingMessages.splice(sendInFlight ? 1 : 0, 1);
    }
    if (bridgeConnected) {
      flushPendingMessages();
    } else {
      nudgeBridge();
    }
  }

  function flushPendingMessages() {
    if (isTornDown || sendInFlight || !bridgeConnected || pendingMessages.length === 0) return;

    const envelope = pendingMessages[0];
    sendInFlight = true;
    sendRuntimeMessage({ type: "native-message", envelope }, (response) => {
      sendInFlight = false;
      // Pause/teardown can intentionally invalidate an in-flight queue entry.
      // The worker may already have delivered it, but it must never be replayed.
      if (pendingMessages[0] !== envelope) {
        queueMicrotask(flushPendingMessages);
        return;
      }
      if (response?.delivered === true && pendingMessages[0] === envelope) {
        pendingMessages.shift();
        queueMicrotask(flushPendingMessages);
        return;
      }
      if (response?.rejected === true && pendingMessages[0] === envelope) {
        // Invalid or oversized page data can never become deliverable. Drop
        // only that permanent failure so it cannot poison the FIFO.
        pendingMessages.shift();
        queueMicrotask(flushPendingMessages);
        return;
      }
      // A non-acknowledgement leaves the item at the head. Wait for the next
      // connected broadcast rather than spinning against a closing worker.
      bridgeConnected = false;
      nudgeBridge();
    });
  }

  function setBridgeConnected(
    connected,
    { incomingInstanceId = null, incomingEpoch = null } = {}
  ) {
    const hasClock =
      typeof incomingInstanceId === "string" &&
      incomingInstanceId.length > 0 &&
      Number.isSafeInteger(incomingEpoch) &&
      incomingEpoch >= 0;
    if (hasClock) {
      if (bridgeInstanceId !== incomingInstanceId) {
        bridgeInstanceId = incomingInstanceId;
        bridgeStateEpoch = -1;
      }
      if (incomingEpoch <= bridgeStateEpoch) return false;
      bridgeStateEpoch = incomingEpoch;
    } else if (bridgeInstanceId !== null) {
      // Once this page has seen versioned state, an unversioned late callback
      // cannot safely overwrite it.
      return false;
    }

    bridgeConnected = connected === true;
    if (bridgeConnected) {
      flushPendingMessages();
    } else {
      dismissRegionHighlight();
    }
    return true;
  }

  function nudgeBridge() {
    if (isTornDown || bridgeNudgeInFlight) return;
    bridgeNudgeInFlight = true;
    sendRuntimeMessage({ type: "retry-connect" }, () => {
      sendRuntimeMessage({ type: "get-connection-state" }, (state) => {
        bridgeNudgeInFlight = false;
        if (typeof state?.connected === "boolean") {
          setBridgeConnected(state.connected, {
            incomingInstanceId: state.bridgeInstanceId,
            incomingEpoch: state.bridgeStateEpoch,
          });
        }
      });
    });
  }

  function sendTabActivity(reason) {
    if (isTornDown || document.visibilityState !== "visible") return;
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
    if (!extensionEnabled || isTornDown) return false;
    const generation = captureGeneration;
    const result = await getHFQuickNoteContext();
    if (!extensionEnabled || isTornDown || generation !== captureGeneration) return false;
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

  function onSelectionChange() {
    if (!extensionEnabled || isTornDown) return;
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(handleSelectionChange, SELECTION_DEBOUNCE_MS);
  }
  document.addEventListener("selectionchange", onSelectionChange);

  async function handleSelectionChange() {
    if (!extensionEnabled || isTornDown) return;
    const generation = captureGeneration;
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;

    const context = await getContextForElement({ selection: true });
    if (!extensionEnabled || isTornDown || generation !== captureGeneration) return;

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

    const generation = captureGeneration;

    // Capture the element and its bounds at click time (before async work)
    const el = document.elementFromPoint(e.clientX, e.clientY);
    const elRect = el ? el.getBoundingClientRect() : null;

    const context = await getContextForElement({
      x: e.clientX,
      y: e.clientY,
    });

    if (!extensionEnabled || isTornDown || generation !== captureGeneration) {
      exitGrabMode();
      return;
    }

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

  // Listen for commands from the popup and the extension worker.
  function handleRuntimeMessage(msg, _sender, sendResponse) {
    switch (msg?.type) {
      case "grab-element":
        sendResponse({ ok: enterGrabMode() });
        return false;
      case "region-select":
        sendResponse({ ok: enterRegionSelectMode() });
        return false;
      case "hf-quick-note":
        triggerHFQuickNote().then((ok) => sendResponse({ ok }));
        return true;
      case "open-settings":
        send("openExtensionSettings", {});
        sendResponse({ ok: true });
        return false;
      case "get-status":
        sendResponse({ available: true, enabled: extensionEnabled });
        return false;
      case "regionQuery":
        void handleRegionQuery(msg.data);
        sendResponse({ ok: true });
        return false;
      case "dismissRegionHighlight":
        dismissRegionHighlight();
        sendResponse({ ok: true });
        return false;
      case "bridge-state":
        setBridgeConnected(msg.connected, {
          incomingInstanceId: msg.bridgeInstanceId,
          incomingEpoch: msg.bridgeStateEpoch,
        });
        sendResponse({ ok: true });
        return false;
      default:
        return false;
    }
  }

  if (typeof chrome !== "undefined" && chrome.runtime) {
    chrome.runtime.onMessage.addListener(handleRuntimeMessage);
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
    const generation = captureGeneration;
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
      if (!extensionEnabled || isTornDown || generation !== captureGeneration) return [];
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
    const generation = captureGeneration;
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
    if (!extensionEnabled || isTornDown || generation !== captureGeneration) {
      exitRegionSelectMode();
      return;
    }

    // Fallback: if grid sampling found nothing, try the element at the center
    if (elements.length === 0) {
      const centerCtx = await getContextForElement({
        x: x + w / 2,
        y: y + h / 2,
      });
      if (!extensionEnabled || isTornDown || generation !== captureGeneration) {
        exitRegionSelectMode();
        return;
      }
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
    if (!extensionEnabled || isTornDown || document.visibilityState !== "visible" || !data) return;
    const generation = captureGeneration;

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
      if (!extensionEnabled || isTornDown || generation !== captureGeneration) return;
      if (selectionContext?.selectedText) elements = [selectionContext];
    }

    if (elements.length === 0 && limit === 1) {
      const context = await getContextForElement({
        x: queryX + (queryRight - queryX) / 2,
        y: queryY + (queryBottom - queryY) / 2,
      });
      if (!extensionEnabled || isTornDown || generation !== captureGeneration) return;
      elements = context ? [context] : [];
    } else if (elements.length === 0) {
      elements = await sampleElementsInRect(queryX, queryY, queryRight - queryX, queryBottom - queryY, limit);
      if (!extensionEnabled || isTornDown || generation !== captureGeneration) return;
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
    if (!extensionEnabled || isTornDown) return;

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

  function onWindowFocus() {
    sendTabActivity("focus");
  }

  function onVisibilityChange() {
    sendTabActivity("visibility");
  }

  function onDocumentMouseDown() {
    sendTabActivity("mousedown");
  }

  function teardownContentScript() {
    if (isTornDown) return;
    isTornDown = true;
    cancelCaptureInteractions();
    clearTimeout(initActivityTimer);
    initActivityTimer = null;
    pendingMessages = [];
    sendInFlight = false;
    bridgeConnected = false;
    bridgeNudgeInFlight = false;

    document.removeEventListener("selectionchange", onSelectionChange);
    document.removeEventListener("keydown", onShortcutKeydown, true);
    window.removeEventListener("focus", onWindowFocus);
    document.removeEventListener("visibilitychange", onVisibilityChange);
    document.removeEventListener("mousedown", onDocumentMouseDown, true);
    chrome.storage?.onChanged?.removeListener(handleStorageChanged);
    chrome.runtime?.onMessage?.removeListener(handleRuntimeMessage);

    if (globalThis.__remarcContentScriptVersion === CONTENT_SCRIPT_VERSION) {
      globalThis.__remarcContentScriptLoaded = false;
      delete globalThis.__remarcContentScriptVersion;
      delete globalThis.__remarcContentScriptTeardown;
    }
  }

  globalThis.__remarcContentScriptTeardown = teardownContentScript;

  document.addEventListener("keydown", onShortcutKeydown, true);
  window.addEventListener("focus", onWindowFocus);
  document.addEventListener("visibilitychange", onVisibilityChange);
  document.addEventListener("mousedown", onDocumentMouseDown, true);

  // --- Init ---
  nudgeBridge();
  initActivityTimer = setTimeout(() => sendTabActivity("init"), 0);
})();
