# Badge Bounce Animation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a bounce animation to the menu bar badge pill when a comment is saved, creating a visual "landing impact" that completes the fly-to-menubar animation.

**Architecture:** Timer-based badge image sequence. Pre-render 6 frames of the indigo pill at escalating scales (bounce curve), swap `button.attributedTitle` every 40ms. Triggered explicitly by the fly animation's completion handler via a new public method on `AppController`.

**Tech Stack:** AppKit (NSStatusBarButton, NSTextAttachment, DispatchSourceTimer, NSImage programmatic drawing)

---

### Task 1: Add `createBadgeImage(count:scale:)` with scale parameter

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift:112-145`

**Step 1: Add scale parameter to `createBadgeImage`**

Replace the existing `createBadgeImage(count:)` with a version that accepts an optional `scale` parameter. When `scale` is 1.0 (default), behavior is identical to current. When scale differs, the pill and text are drawn at `size * scale`.

```swift
private func createBadgeImage(count: Int, scale: CGFloat = 1.0) -> NSImage {
    let text = "\(count)"
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let textSize = (text as NSString).size(withAttributes: attributes)
    let height: CGFloat = 18
    let diameter = max(height, textSize.width + 10)

    // Scale the drawing size
    let scaledWidth = diameter * scale
    let scaledHeight = height * scale
    let size = NSSize(width: scaledWidth, height: scaledHeight)

    let image = NSImage(size: size, flipped: false) { rect in
        // Filled pill in brand color
        // Soft Indigo primary — light mode #6366F1
        let fillColor = NSColor(red: 0.388, green: 0.400, blue: 0.945, alpha: 1.0)
        fillColor.setFill()
        let circlePath = NSBezierPath(roundedRect: rect,
                                      xRadius: rect.height / 2, yRadius: rect.height / 2)
        circlePath.fill()

        // Draw count text centered (scale the font)
        let scaledFont = NSFont.monospacedDigitSystemFont(ofSize: 10 * scale, weight: .bold)
        let scaledAttributes: [NSAttributedString.Key: Any] = [
            .font: scaledFont,
            .foregroundColor: NSColor.white,
        ]
        let scaledTextSize = (text as NSString).size(withAttributes: scaledAttributes)
        let textRect = CGRect(
            x: (rect.width - scaledTextSize.width) / 2,
            y: (rect.height - scaledTextSize.height) / 2 + 0.5 * scale,
            width: scaledTextSize.width,
            height: scaledTextSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: scaledAttributes)
        return true
    }
    image.isTemplate = false
    return image
}
```

**Step 2: Build to verify no regressions**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/AppController.swift
git commit -m "feat: add scale parameter to createBadgeImage for bounce animation"
```

---

### Task 2: Add `animateBadgeBounce()` method and bounce timer

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`

**Step 1: Add stored property for bounce timer**

Add after `private var cancellables = Set<AnyCancellable>()` (line 14):

```swift
private var bounceTimer: DispatchSourceTimer?
```

**Step 2: Add `animateBadgeBounce()` public method**

Add after `updateBadge(count:)` (after line 110), before `createBadgeImage`:

```swift
/// Animate the badge pill with a bounce effect (pop in and settle).
/// Call from fly-animation completion handlers for a "landing impact" feel.
public func animateBadgeBounce() {
    guard let button = statusItem?.button else { return }
    let count = PersistenceManager.shared.appState.comments.filter { !$0.isDeleted }.count
    guard count > 0 else { return }

    // Cancel any in-progress bounce
    bounceTimer?.cancel()
    bounceTimer = nil

    // Bounce curve: pop in from tiny, overshoot, settle
    let scales: [CGFloat] = [0.01, 1.15, 0.92, 1.05, 0.98, 1.0]

    // Pre-render all frames
    let fullSizeImage = createBadgeImage(count: count)
    let fullWidth = fullSizeImage.size.width
    let fullHeight = fullSizeImage.size.height

    let frames: [(image: NSImage, bounds: CGRect)] = scales.map { scale in
        let img = createBadgeImage(count: count, scale: scale)
        // Center the scaled badge on the same point as the full-size badge
        let bounds = CGRect(
            x: -(fullWidth * (scale - 1) / 2),
            y: -5 - (fullHeight * (scale - 1) / 2),
            width: fullWidth * scale,
            height: fullHeight * scale
        )
        return (img, bounds)
    }

    var frameIndex = 0
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(40))
    timer.setEventHandler { [weak self] in
        guard let self, frameIndex < frames.count else {
            timer.cancel()
            self?.bounceTimer = nil
            return
        }
        let frame = frames[frameIndex]
        let attachment = NSTextAttachment()
        attachment.image = frame.image
        attachment.bounds = frame.bounds
        let attachmentString = NSAttributedString(attachment: attachment)
        let attributed = NSMutableAttributedString(string: " ")
        attributed.append(attachmentString)
        button.attributedTitle = attributed
        frameIndex += 1
    }
    bounceTimer = timer
    timer.resume()
}
```

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/AppController.swift
git commit -m "feat: add animateBadgeBounce() with timer-based image sequence"
```

---

### Task 3: Trigger bounce from text comment fly animation

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift:326-334`

**Step 1: Add bounce call to `dismissWithAnimation()` completion handler**

In `dismissWithAnimation()`, the completion handler currently reads:

```swift
} completionHandler: {
    panel.orderOut(nil)
    panel.alphaValue = 1  // Reset for next show
}
```

Change to:

```swift
} completionHandler: {
    panel.orderOut(nil)
    panel.alphaValue = 1  // Reset for next show
    AppController.shared.animateBadgeBounce()
}
```

This is at line 331-334 of `CommentInputWindowController.swift`.

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 3: Manual test**

1. Kill and relaunch Remarc (extract path from build output)
2. Select text in any app, save a comment
3. Watch the fly animation — when the panel reaches the menu bar, the badge pill should pop in with a bounce

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift
git commit -m "feat: trigger badge bounce on text comment save"
```

---

### Task 4: Trigger bounce from screenshot comment fly animation

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift:213-231`

**Step 1: Add bounce call to Phase 3 screenshot completion handler**

In the Phase 3 completion handler (line 213-231), after `commitCapture` creates the comment, add a delayed bounce. The delay lets the Combine pipeline deliver the new count before we animate.

Current code at line 213-231:

```swift
} completionHandler: {
    borderPanel.orderOut(nil)

    // All animations done — capture the screen
    ScreenCaptureService.shared.commitCapture { imagePath in
        let reference = CommentReference.screenshot(imagePath: imagePath)
        let comment = PersistenceManager.shared.createComment(
            reference: reference,
            commentText: commentText,
            source: "Screenshot",
            appBundleID: nil
        )
        if let comment = comment {
            LicenseManager.shared.recordComment()
            debugLog("CommentInputController: Screenshot comment saved (id=\(comment.id))")
        } else {
            debugLog("CommentInputController: Screenshot comment save FAILED")
        }
    }
}
```

Change to:

```swift
} completionHandler: {
    borderPanel.orderOut(nil)

    // All animations done — capture the screen
    ScreenCaptureService.shared.commitCapture { imagePath in
        let reference = CommentReference.screenshot(imagePath: imagePath)
        let comment = PersistenceManager.shared.createComment(
            reference: reference,
            commentText: commentText,
            source: "Screenshot",
            appBundleID: nil
        )
        if let comment = comment {
            LicenseManager.shared.recordComment()
            debugLog("CommentInputController: Screenshot comment saved (id=\(comment.id))")
            // Brief delay lets Combine pipeline deliver the new count
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AppController.shared.animateBadgeBounce()
            }
        } else {
            debugLog("CommentInputController: Screenshot comment save FAILED")
        }
    }
}
```

**Step 2: Also add bounce to the no-selection-rect screenshot path**

The else branch at line 233-252 also saves a screenshot comment. Add the same bounce there.

Current code at line 234-251:

```swift
// No selection rect — just capture after overlay fades
DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    ScreenCaptureService.shared.commitCapture { imagePath in
        let reference = CommentReference.screenshot(imagePath: imagePath)
        let comment = PersistenceManager.shared.createComment(
            reference: reference,
            commentText: commentText,
            source: "Screenshot",
            appBundleID: nil
        )
        if let comment = comment {
            LicenseManager.shared.recordComment()
            debugLog("CommentInputController: Screenshot comment saved (id=\(comment.id))")
        } else {
            debugLog("CommentInputController: Screenshot comment save FAILED")
        }
    }
}
```

Change the success branch to:

```swift
if let comment = comment {
    LicenseManager.shared.recordComment()
    debugLog("CommentInputController: Screenshot comment saved (id=\(comment.id))")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        AppController.shared.animateBadgeBounce()
    }
} else {
```

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Manual test**

1. Kill and relaunch Remarc
2. Take a screenshot comment — watch for badge bounce after the selection border flies to menu bar
3. Verify text comment bounce still works too

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift
git commit -m "feat: trigger badge bounce on screenshot comment save"
```

---

### Task 5: Tune and verify

**Step 1: Launch and test all save paths**

Kill and relaunch Remarc from the build output path.

Test matrix:
- Text selection comment → fly + bounce
- Quick note (no selection) → fly + bounce
- Screenshot with selection rect → 3-phase fly + bounce
- Rapid double-save → second bounce cancels first, plays clean

**Step 2: Tune if needed**

Adjustable parameters in `animateBadgeBounce()`:
- `scales` array — change overshoot amount (1.15 → 1.2 for more dramatic, 1.1 for subtler)
- Timer interval — 40ms is ~25fps; try 33ms (~30fps) if it looks choppy
- Number of frames — add intermediate frames if the settle phase needs smoothing

**Step 3: Final commit if tuning was needed**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/AppController.swift
git commit -m "refine: tune badge bounce animation parameters"
```
