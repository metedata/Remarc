# Badge Bounce Animation Design

## Problem

The fly-to-menubar animation on comment save doesn't have a clean finish. The comment count badge should visually acknowledge the incoming comment with a bounce effect.

## Solution

Timer-based badge image sequence. Pre-render 6 frames of the badge pill at different scales following a bounce curve, swap `button.attributedTitle` every ~40ms. Total duration ~240ms.

## Bounce Curve

```
scales: [0.01, 1.15, 0.92, 1.05, 0.98, 1.0]
```

Pop in from nothing, overshoot, settle. 6 frames at 40ms = 240ms total.

## Changes

### AppController.swift

1. **`createBadgeImage(count:scale:)`** — New scale parameter (default 1.0). Renders pill at `size * scale`. Attachment bounds adjusted to keep bounce centered:
   ```
   bounds.width = w * s
   bounds.height = h * s
   bounds.y = -5 - (h * (s - 1) / 2)
   bounds.x = -(w * (s - 1) / 2)
   ```

2. **`animateBadgeBounce()`** — Public method. Pre-renders 6 frames, fires `DispatchSourceTimer` at 40ms intervals swapping `button.attributedTitle`. Cancels any in-progress bounce first.

3. **`bounceTimer: DispatchSourceTimer?`** — Stored property for cancellation.

### CommentInputWindowController.swift

Two trigger call sites:

1. **Text comments** — `dismissWithAnimation()` completion handler: call `AppController.shared.animateBadgeBounce()` after `panel.orderOut`.

2. **Screenshot comments** — Phase 3 completion handler: call `AppController.shared.animateBadgeBounce()` after `commitCapture` with a 50ms delay to let the Combine badge count pipeline deliver first.

## Edge Cases

- **Count is 0**: bounce is a no-op.
- **Rapid saves**: new bounce cancels in-progress bounce, starts fresh with current count.
- **Paused state**: no handling needed — can't save comments while paused.

## Approach Rationale

Timer-based image swapping is the standard technique for menu bar animations on macOS. Direct Core Animation on `NSStatusBarButton` conflicts with the system's geometry management and causes rendering artifacts. This approach extends the existing `createBadgeImage` infrastructure with zero risk.
