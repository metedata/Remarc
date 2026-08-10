// popup.js — Extension popup UI logic

(function () {
  "use strict";

  const statusDot = document.getElementById("statusDot");
  const statusText = document.getElementById("statusText");
  const grabBtn = document.getElementById("grabBtn");
  const regionBtn = document.getElementById("regionBtn");
  const powerBtn = document.getElementById("powerBtn");
  const pauseIcon = document.getElementById("pauseIcon");
  const playIcon = document.getElementById("playIcon");
  const statusPill = document.getElementById("statusPill");
  const settingsBtn = document.getElementById("settingsBtn");
  const reconnectHint = document.getElementById("reconnectHint");
  const reconnectText = document.getElementById("reconnectText");
  const reconnectBtn = document.getElementById("reconnectBtn");

  function formatShortcut(config) {
    const symbolMap = { Meta: "\u2318", Control: "\u2303", Alt: "\u2325", Shift: "\u21E7" };
    const order = ["Control", "Alt", "Shift", "Meta"];
    const symbols = order
      .filter((m) => config.modifiers.includes(m))
      .map((m) => symbolMap[m])
      .join("");
    return symbols + config.key.toUpperCase();
  }

  function updateShortcutLabels() {
    const defaults = {
      "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
      "region-select": { key: "R", modifiers: ["Alt", "Shift"] },
    };

    chrome.storage.local.get("shortcuts", (result) => {
      const shortcuts = result.shortcuts || defaults;
      document.getElementById("grabShortcut").textContent = formatShortcut(
        shortcuts["grab-element"] || defaults["grab-element"]
      );
      document.getElementById("regionShortcut").textContent = formatShortcut(
        shortcuts["region-select"] || defaults["region-select"]
      );
    });
  }

  updateShortcutLabels();

  let isEnabled = true;
  let isConnected = false;
  let canControlActiveTab = false;
  let isLNABlocked = false;
  let activeTabId = null;

  // --- State rendering ---
  // Connection state comes from the background badge state; tab control is checked separately.

  function isInjectableTab(tab) {
    return /^https?:\/\//.test(tab?.url || "") || /^file:\/\//.test(tab?.url || "");
  }

  function render() {
    const controlsAvailable = isConnected && canControlActiveTab;
    const active = controlsAvailable && isEnabled;
    const needsTabReload = isConnected && isEnabled && !canControlActiveTab;

    // Buttons only work when active
    grabBtn.disabled = !active;
    regionBtn.disabled = !active;
    settingsBtn.disabled = !controlsAvailable;

    // Power button only visible when connected
    powerBtn.style.display = isConnected ? "" : "none";
    pauseIcon.style.display = isEnabled ? "" : "none";
    playIcon.style.display = isEnabled ? "none" : "";
    powerBtn.title = isEnabled ? "Pause extension" : "Resume extension";
    powerBtn.classList.toggle("paused", !isEnabled);

    // Hint priority: browser policy blocks the site from reaching localhost
    // > tab reload (orphaned content script) > reload-to-connect.
    // Chrome's permission is "Apps on Device" (Chrome 145+, the loopback-network
    // half of the LNA split; "Local network" is a separate permission for
    // routers/printers that we don't need). Arc still labels theirs
    // "Loopback Network".
    if (isLNABlocked) {
      reconnectHint.style.display = "";
      reconnectHint.classList.add("lna");
      reconnectText.textContent = "Allow “Apps on Device” for this site.";
      reconnectBtn.title = "Open this site's permissions";
    } else {
      reconnectHint.classList.remove("lna");
      reconnectHint.style.display = !isConnected || needsTabReload ? "" : "none";
      reconnectText.textContent = needsTabReload ? "Reload page to enable controls" : "Reload page to connect";
      reconnectBtn.title = "Reload page";
    }

    // Status indicator
    if (isLNABlocked) {
      statusDot.className = "status-dot blocked";
      statusText.textContent = "Blocked";
      statusPill.title =
        "This site can't reach Remarc. In Chrome, set “Apps on Device” to " +
        "Allow for this site (in Arc, it's “Loopback Network”). “Local network” " +
        "is a different permission - you can leave that one as-is.";
    } else if (!isConnected) {
      statusDot.className = "status-dot";
      statusText.textContent = "Disconnected";
      statusPill.title = "Launch Remarc macOS app to connect";
    } else if (!isEnabled) {
      statusDot.className = "status-dot paused";
      statusText.textContent = "Paused";
      statusPill.title = "";
    } else {
      statusDot.className = "status-dot connected";
      statusText.textContent = "Connected";
      statusPill.title = needsTabReload ? "Remarc is connected. Reload this page to enable popup controls." : "";
    }
  }

  // --- Init ---

  chrome.storage.local.get({ extensionEnabled: true }, (result) => {
    isEnabled = result.extensionEnabled;
    queryConnectionStatus();
  });

  // --- Power button ---

  powerBtn.addEventListener("click", () => {
    isEnabled = !isEnabled;
    chrome.storage.local.set({ extensionEnabled: isEnabled });
    render();
    // Icon update handled by background.js via storage change listener
  });

  // --- Connection status ---

  function queryConnectionStatus() {
    // Opportunistic retry: popup opening typically signals the user just
    // changed a Chrome setting (loopback permission), started the app, or
    // came back to check status. Existing cooldowns in content.js are stale
    // in that case, so nudge it to retry now. The synchronous LNA re-check
    // updates lnaBlocked inside content.js's connect() immediately, and a
    // localhost handshake usually completes well under 200ms - long enough
    // before we query final status.
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      const nudge = (cb) => {
        if (!tab?.id) return cb();
        chrome.tabs.sendMessage(tab.id, { type: "retry-connect" }, () => {
          void chrome.runtime.lastError;
          setTimeout(cb, 200);
        });
      };
      nudge(() => {
        chrome.runtime.sendMessage({ type: "get-connection-state" }, (state) => {
          const globalConnected = chrome.runtime.lastError ? false : !!state?.connected;
          queryActiveTabStatus(globalConnected);
        });
      });
    });
  }

  function queryActiveTabStatus(globalConnected) {
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      activeTabId = tab?.id ?? null;
      if (!tab?.id) {
        isConnected = globalConnected;
        canControlActiveTab = false;
        isLNABlocked = false;
        render();
        return;
      }
      chrome.tabs.sendMessage(tab.id, { type: "get-status" }, (response) => {
        const tabConnected = !!response?.connected;
        if (chrome.runtime.lastError) {
          isConnected = globalConnected;
          canControlActiveTab = isInjectableTab(tab);
          isLNABlocked = false;
        } else {
          isConnected = globalConnected || tabConnected;
          canControlActiveTab = !!response?.available || tabConnected;
          // Only surface LNA hint when the active tab itself can't connect —
          // global state might be true via other tabs that aren't LNA-blocked.
          isLNABlocked = !!response?.lnaBlocked && !tabConnected;
        }
        render();
      });
    });
  }

  // --- Action buttons ---

  function injectContentScripts(tabId, callback) {
    if (!chrome.scripting?.executeScript) {
      callback(false);
      return;
    }

    chrome.scripting.executeScript(
      {
        target: { tabId },
        files: ["main-world.js"],
        world: "MAIN",
      },
      () => {
        if (chrome.runtime.lastError) {
          callback(false);
          return;
        }

        chrome.scripting.executeScript(
          {
            target: { tabId },
            files: ["content.js"],
            world: "ISOLATED",
          },
          () => callback(!chrome.runtime.lastError)
        );
      }
    );
  }

  function showTabUnavailable() {
    canControlActiveTab = false;
    render();
    reconnectHint.style.display = "";
    reconnectText.textContent = "Reload page to enable controls";
  }

  function sendToTab(type) {
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      if (!tab?.id || !isInjectableTab(tab)) {
        showTabUnavailable();
        return;
      }

      const sendCommand = () => {
        chrome.tabs.sendMessage(tab.id, { type }, (response) => {
          if (chrome.runtime.lastError || response?.ok === false) {
            showTabUnavailable();
            return;
          }
          window.close();
        });
      };

      chrome.tabs.sendMessage(tab.id, { type: "get-status" }, () => {
        if (chrome.runtime.lastError) {
          injectContentScripts(tab.id, (injected) => {
            if (!injected) {
              showTabUnavailable();
              return;
            }
            sendCommand();
          });
        } else {
          sendCommand();
        }
      });
    });
  }

  grabBtn.addEventListener("click", () => sendToTab("grab-element"));
  regionBtn.addEventListener("click", () => sendToTab("region-select"));

  // --- Reconnect ---

  document.getElementById("reconnectBtn").addEventListener("click", () => {
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      if (!tab?.id) return;
      if (isLNABlocked) {
        // Open the site's permissions page. siteDetails wants an origin, not
        // a full URL with path/query - parse defensively and fall back to the
        // global content settings page if the origin can't be extracted.
        let origin = null;
        try {
          if (tab.url) origin = new URL(tab.url).origin;
        } catch {}
        const url = origin
          ? `chrome://settings/content/siteDetails?site=${encodeURIComponent(origin)}`
          : "chrome://settings/content";
        chrome.tabs.create({ url });
        // Nudge the content script to retry on next status check.
        chrome.tabs.sendMessage(tab.id, { type: "retry-connect" }, () => void chrome.runtime.lastError);
        window.close();
      } else {
        chrome.tabs.reload(tab.id, () => {
          window.close();
        });
      }
    });
  });

  // --- Settings ---

  settingsBtn.addEventListener("click", () => {
    chrome.tabs.query({ active: true, currentWindow: true }, ([tab]) => {
      if (tab?.id) {
        chrome.tabs.sendMessage(tab.id, { type: "open-settings" }, () => {
          window.close();
        });
      }
    });
  });
})();
