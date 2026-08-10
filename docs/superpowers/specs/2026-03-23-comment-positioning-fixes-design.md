# Comment Positioning Fixes - Design Spec

**Date:** 2026-03-23
**Status:** Approved

## Problem

Three related issues with comment positioning in browsers (particularly Arc with its sidebar):

1. **Region select offset with Arc sidebar** - The viewport-to-screen coordinate conversion doesn't account for horizontal browser chrome (sidebars). The comment panel appears offset by the sidebar width.
2. **Element grab panel centers instead of anchoring** - `grabClick` doesn't send position data, so the comment panel falls back to centering on screen instead of appearing adjacent to the element.
3. **Region highlight disappears while composing** - A hardcoded 60-second safety timeout auto-dismisses the highlight even when the user is still typing/dictating.

## Changes

### 1. Horizontal chrome offset in `extension/content.js`

**`finalizeRegionSelection`** (line 439-445): Add a `sidebarOffset` mirroring the existing vertical `chromeOffset`.

Before:
```javascript
const chromeOffset = window.outerHeight - window.innerHeight;
send("regionRect", {
  x: window.screenX + x,
  y: window.screenY + chromeOffset + y,
  width: w,
  height: h,
});
```

After:
```javascript
const chromeOffset = window.outerHeight - window.innerHeight;
const sidebarOffset = window.outerWidth - window.innerWidth;
send("regionRect", {
  x: window.screenX + sidebarOffset + x,
  y: window.screenY + chromeOffset + y,
  width: w,
  height: h,
});
```

**`handleRegionQuery`** (line 512-522): Apply the same sidebar offset when converting screen coordinates back to viewport coordinates.

Before:
```javascript
const vpX = screenX - window.screenX;
const vpY = screenY - window.screenY;
```

After:
```javascript
const sidebarOffset = window.outerWidth - window.innerWidth;
const vpX = screenX - window.screenX - sidebarOffset;
const vpY = screenY - window.screenY;
```

`outerWidth - innerWidth` is 0 on standard Chrome/Firefox (no sidebar), so this is a no-op for browsers without sidebars.

### 2. Send regionRect from element grab in `extension/content.js`

In `grabClick` (line 217-231), after resolving the element context, send a `regionRect` using the clicked element's bounding box converted to screen coordinates (with the same `sidebarOffset` + `chromeOffset` conversion).

```javascript
async function grabClick(e) {
  e.preventDefault();
  e.stopPropagation();

  const el = document.elementFromPoint(e.clientX, e.clientY);
  const context = await getContextForElement({
    x: e.clientX,
    y: e.clientY,
  });

  if (context) {
    // Send position data so the panel anchors adjacent to the element
    const rect = el ? el.getBoundingClientRect() : null;
    if (rect) {
      const chromeOffset = window.outerHeight - window.innerHeight;
      const sidebarOffset = window.outerWidth - window.innerWidth;
      send("regionRect", {
        x: window.screenX + sidebarOffset + rect.left,
        y: window.screenY + chromeOffset + rect.top,
        width: rect.width,
        height: rect.height,
      });
    }
    send("elementGrab", context);
  }

  exitGrabMode();
}
```

The native side already consumes `regionRect` before `elementGrab` arrives (with an 0.8s fallback), and `showForWebElement` uses `pendingRegionScreenRect` with `useAdjacentPositioning: true` when it's set. So this "just works" with the existing native flow.

### 3. Remove highlight timeout in `extension/content.js`

In `enterPersistentHighlight` (line 466-486):
- Remove the `setTimeout` that auto-dismisses after 60 seconds.
- Remove the `regionHighlightTimeout` variable and its `clearTimeout` in `dismissRegionHighlight`.

The highlight now lives until:
- The native side sends a dismiss message (when the panel closes)
- The user presses Escape

## Files Changed

| File | Change |
|------|--------|
| `extension/content.js` | All three fixes |

No native-side changes needed. The native coordinate conversion (`WebSocketService.swift`) and panel positioning (`CommentInputWindowController.swift`) already handle `regionRect` correctly.
