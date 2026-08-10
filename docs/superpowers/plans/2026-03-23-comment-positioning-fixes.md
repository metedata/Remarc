# Comment Positioning Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three comment positioning bugs: Arc sidebar offset, element grab centering, and highlight timeout.

**Architecture:** All fixes are in `extension/content.js`. Add horizontal chrome offset to coordinate conversions, send regionRect from element grabs, and remove the 60-second highlight timeout.

**Tech Stack:** Browser extension JavaScript (Chrome Extension Manifest V3)

**Spec:** `docs/superpowers/specs/2026-03-23-comment-positioning-fixes-design.md`

---

### Task 1: Add horizontal sidebar offset to region select coordinates

**Files:**
- Modify: `extension/content.js:436-445` (finalizeRegionSelection - regionRect send)
- Modify: `extension/content.js:512-522` (handleRegionQuery - reverse conversion)

- [ ] **Step 1: Add sidebarOffset to finalizeRegionSelection**

In `finalizeRegionSelection`, add a `sidebarOffset` calculation and apply it to the X coordinate in the `regionRect` message. Find this code (around line 436-445):

```javascript
    // 5. Send region screen rect (for panel positioning), then context to app.
    // x is global screen coordinate; y is in global Quartz coordinates.
    // Native side converts y to AppKit using the primary screen height.
    const chromeOffset = window.outerHeight - window.innerHeight;
    send("regionRect", {
      x: window.screenX + x,
      y: window.screenY + chromeOffset + y,
      width: w,
      height: h,
    });
```

Replace with:

```javascript
    // 5. Send region screen rect (for panel positioning), then context to app.
    // x/y are viewport-relative; convert to global screen coordinates.
    // chromeOffset accounts for vertical browser chrome (tabs, address bar).
    // sidebarOffset accounts for horizontal browser chrome (e.g. Arc sidebar).
    // Native side converts y from Quartz to AppKit using the primary screen height.
    const chromeOffset = window.outerHeight - window.innerHeight;
    const sidebarOffset = window.outerWidth - window.innerWidth;
    send("regionRect", {
      x: window.screenX + sidebarOffset + x,
      y: window.screenY + chromeOffset + y,
      width: w,
      height: h,
    });
```

- [ ] **Step 2: Apply sidebarOffset to handleRegionQuery reverse conversion**

In `handleRegionQuery` (around line 512-522), apply the sidebar offset when converting screen coordinates back to viewport coordinates:

```javascript
  async function handleRegionQuery(data) {
    const { screenX, screenY, width, height } = data;

    const vpX = screenX - window.screenX;
    const vpY = screenY - window.screenY;
```

Replace the vpX/vpY lines with:

```javascript
  async function handleRegionQuery(data) {
    const { screenX, screenY, width, height } = data;

    const sidebarOffset = window.outerWidth - window.innerWidth;
    const vpX = screenX - window.screenX - sidebarOffset;
    const vpY = screenY - window.screenY;
```

- [ ] **Step 3: Test manually**

1. Open Arc browser with sidebar visible
2. Use region select (Alt+Shift+R) to highlight an area
3. Verify the comment panel appears adjacent to the highlighted region, not offset inward
4. Close Arc sidebar, repeat - verify positioning still works correctly
5. Test in standard Chrome (no sidebar) - verify no regression

- [ ] **Step 4: Commit**

```bash
git add extension/content.js
git commit -m "fix: account for horizontal browser chrome in region select coordinates"
```

---

### Task 2: Send regionRect from element grab for adjacent positioning

**Files:**
- Modify: `extension/content.js:217-231` (grabClick function)

- [ ] **Step 1: Update grabClick to send regionRect before elementGrab**

Find the current `grabClick` function (around line 217-231):

```javascript
  async function grabClick(e) {
    e.preventDefault();
    e.stopPropagation();

    const context = await getContextForElement({
      x: e.clientX,
      y: e.clientY,
    });

    if (context) {
      send("elementGrab", context);
    }

    exitGrabMode();
  }
```

Replace with:

```javascript
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

    if (context) {
      // Send position data so the comment panel anchors adjacent to the element
      // rather than centering on screen. Must arrive before elementGrab.
      if (elRect) {
        const chromeOffset = window.outerHeight - window.innerHeight;
        const sidebarOffset = window.outerWidth - window.innerWidth;
        send("regionRect", {
          x: window.screenX + sidebarOffset + elRect.left,
          y: window.screenY + chromeOffset + elRect.top,
          width: elRect.width,
          height: elRect.height,
        });
      }
      send("elementGrab", context);
    }

    exitGrabMode();
  }
```

Key details:
- `el` and `elRect` are captured synchronously at click time, before `getContextForElement` (which is async). This ensures the bounding box reflects the element's position at click, not after the async round-trip.
- `regionRect` is sent before `elementGrab` so the native side stores `pendingRegionScreenRect` before `showForWebElement` consumes it.
- The native side already has a 0.8s fallback timer for `regionRect` without `elementGrab` - sending both in sequence over the same WebSocket guarantees ordering.

- [ ] **Step 2: Test manually**

1. Open any browser page
2. Enter grab mode (Alt+Shift+G), click an element
3. Verify the comment panel appears adjacent to the clicked element (right side preferred, with fallback to left/above/below)
4. Previously it appeared centered on screen - confirm it no longer does
5. Test with Arc sidebar open - verify the panel position accounts for the sidebar

- [ ] **Step 3: Commit**

```bash
git add extension/content.js
git commit -m "fix: send element bounds from grab mode for adjacent panel positioning"
```

---

### Task 3: Remove region highlight timeout

**Files:**
- Modify: `extension/content.js:22-23` (regionHighlightTimeout variable)
- Modify: `extension/content.js:466-486` (enterPersistentHighlight)
- Modify: `extension/content.js:488-501` (dismissRegionHighlight)

- [ ] **Step 1: Remove the regionHighlightTimeout variable declaration**

Find (around line 22-23):

```javascript
  // Persistent region highlight state
  let regionHighlightActive = false;
  let regionHighlightTimeout = null;
```

Replace with:

```javascript
  // Persistent region highlight state
  let regionHighlightActive = false;
```

- [ ] **Step 2: Remove the setTimeout from enterPersistentHighlight**

Find (around line 466-486):

```javascript
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

    // Safety timeout — auto-dismiss after 60s
    regionHighlightTimeout = setTimeout(() => {
      dismissRegionHighlight();
      send("regionHighlightDismissed", {});
    }, 60000);
  }
```

Replace with:

```javascript
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
```

- [ ] **Step 3: Remove clearTimeout from dismissRegionHighlight**

Find (around line 488-501):

```javascript
  function dismissRegionHighlight() {
    if (!regionHighlightActive) return;
    regionHighlightActive = false;

    regionSelectionDiv?.remove();
    regionSelectionDiv = null;

    if (regionHighlightTimeout) {
      clearTimeout(regionHighlightTimeout);
      regionHighlightTimeout = null;
    }

    document.removeEventListener("keydown", highlightKeyDown, true);
  }
```

Replace with:

```javascript
  function dismissRegionHighlight() {
    if (!regionHighlightActive) return;
    regionHighlightActive = false;

    regionSelectionDiv?.remove();
    regionSelectionDiv = null;

    document.removeEventListener("keydown", highlightKeyDown, true);
  }
```

- [ ] **Step 4: Test manually**

1. Use region select to highlight an area in the browser
2. Start typing a comment (or dictating via voice)
3. Wait longer than 60 seconds while composing
4. Verify the highlight stays visible the entire time
5. Save or dismiss the comment - verify the highlight disappears
6. Test Escape key - verify it still dismisses the highlight

- [ ] **Step 5: Commit**

```bash
git add extension/content.js
git commit -m "fix: remove region highlight timeout so it persists while composing"
```
