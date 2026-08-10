# Genie Animation: Research, Attempts, and Recommendations

## Goal

Animate the comment input panel dismissal with a genie-like warp effect toward the menu bar icon when the user saves a comment. Provide a Preferences toggle between the genie effect and a simple fade-out.

## What's Been Built

- **GenieAnimator.swift** — SpriteKit-based warp using `SKWarpGeometryGrid` (1 col x 40 rows, 30 keyframes over 0.5s)
- **bounceBadge()** in AppController — `CAKeyframeAnimation` spring-scale on the status bar button
- **Settings toggle** — `useGenieAnimation` bool in SettingsManager, toggle in Preferences General tab
- **Non-genie path** — Subtle float-up (30pt) + fade-out over 0.25s with ease-out

## The Persistent Problem: White Flash

Every SpriteKit-based approach produces a white flash on the screen when the animation starts. The flash does NOT happen on the first save but happens on most subsequent saves.

### Root Cause

**SKView has a known bug (Apple Radar 16153326)** where its first rendered frame is opaque white despite `allowsTransparency = true`. The SpriteKit rendering pipeline needs at least one display-link tick to render transparent content. During that tick, the SKView composites an opaque white rectangle.

### Why It's Intermittent

The flash doesn't happen on the first save because the GPU pipeline is "cold" and initializes quickly. On subsequent saves, a new SKView is created each time while the previous SpriteKit resources may still be tearing down, causing a brief stall that makes the white frame visible.

## Attempted Fixes (All Failed or Unreliable)

### Attempt 1: Show overlay, delay hiding original panel
- Show the SpriteKit overlay immediately
- Hide original panel after 2-frame delay (33ms)
- **Result**: Worked initially but the flash returned when we changed other code. The timing is inherently racy.

### Attempt 2: CGWindowListCreateImage for snapshot
- Switched from `bitmapImageRepForCachingDisplay` to `CGWindowListCreateImage`
- **Result**: `CGWindowListCreateImage` is deprecated in macOS 15 and requires Screen Recording permission. Without permission, it returns a blank/white image, making the flash worse.

### Attempt 3: Keep original panel visible during entire animation
- Never hide the original panel (let it sit behind the overlay)
- **Result**: User could see the original panel slowly disappearing behind the animated copy. Looked fake.

### Attempt 4: 2-frame delay before hiding original
- Show overlay, wait exactly 2 frames (33ms), then hide original
- **Result**: Worked for a while, then flash returned intermittently. The 2-frame timing is not reliable across different system loads.

### Attempt 5: Defer all @Published state changes to completion handler
- Moved `isVisible = false` and `currentSelection = nil` to animation completion callback
- **Result**: No effect on the flash. The flash is from SKView, not from SwiftUI re-rendering.

### Attempt 6: Scene delegate (didRenderScene) to detect first render
- Set overlay `alphaValue = 0`, wait for `SKSceneDelegate.didRenderScene` callback, then reveal
- **Result**: **Broke the animation entirely.** SpriteKit does not render when the hosting window is at `alphaValue = 0`. The callback never fired, so the overlay was never revealed and the original panel was never hidden.

### Attempt 7: Static snapshot cover over SKView
- Place an NSImageView with the snapshot on top of the SKView at the panel's exact position
- Hide original panel immediately (covered by the static image)
- Remove the cover after 3 frames (50ms)
- **Result**: Worked for the first few comments, then the flash returned. The cover removal timing is still racy — sometimes SpriteKit hasn't rendered past its white frame in 3 ticks.

## Conclusion on SpriteKit Approach

The SpriteKit white flash is a **fundamental platform limitation** that cannot be reliably worked around with timing tricks. Every fix is a band-aid over an asynchronous rendering pipeline we don't control. The core issue is that SKView's first rendered frame is always opaque, and there's no synchronous API to force a transparent render before showing the view.

---

## Alternative Approaches Researched

### Option A: CALayer Strip Slicing (BCGenieEffect Pattern)

**Source**: [BCGenieEffect](https://github.com/Ciechan/BCGenieEffect) — 1400+ stars, battle-tested

**How it works**:
1. Snapshot the panel content into a bitmap
2. Slice the bitmap into ~30-40 horizontal `CALayer` strips (10px each)
3. For each animation frame, compute a trapezoid shape for each strip using bezier curves
4. Convert each trapezoid to a `CATransform3D` perspective matrix (homography)
5. Pre-compute ALL frames and fire as `CAKeyframeAnimation` with discrete calculation mode
6. All strips animate simultaneously with computed transforms

**Two-phase animation**:
- Phase 1 (0%-40%): Bottom edge shears — bezier curves funnel the bottom toward the target while top stays fixed
- Phase 2 (30%-100%): Entire content slides toward target
- The 30%-40% overlap creates the fluid genie feel

**Pros**:
- Pure Core Animation — no SpriteKit, no Metal, no external frameworks
- No white flash — CALayers with bitmap content render immediately
- Mathematically precise — Newton-Raphson bezier solving, double-precision transforms
- Battle-tested in production
- ~400 lines of code, self-contained

**Cons**:
- Creates ~40 CALayers per animation (moderate overhead, but each is just a bitmap strip)
- Snapshot-based (no live material blur in the animation)
- Originally Objective-C/iOS — needs porting to Swift/macOS
- Discrete animation (pre-computed frames, not interpolated)

**Assessment**: **Best candidate for replacing SpriteKit.** Same visual result, no flash issue.

### Option B: Metal Shader via SwiftUI `.distortionEffect()`

**Source**: [alexwidua/genie](https://github.com/alexwidua/genie)

**How it works**:
1. A Metal shader function marked `[[ stitchable ]]` runs per-pixel on the GPU
2. SwiftUI's `.distortionEffect()` modifier applies the shader to a view
3. The shader remaps each pixel's position to create the warp
4. SwiftUI's `Animatable` protocol drives the shader parameters with spring/easing curves

**Pros**:
- Live distortion — no snapshot needed, animates actual view content
- GPU-accelerated, guaranteed 60fps
- Simple code (~200 lines)
- Available on macOS 14+ (our minimum)

**Cons**:
- iOS-only as written — needs porting
- `.distortionEffect()` cannot extend beyond parent bounds — needs oversized overlay
- Would need to snapshot the panel and display in a SwiftUI Image within an overlay (our panel is AppKit)
- Uses a hack (blurred black rectangle) to hide the convergence point
- `maxSampleOffset: CGSize(width: 500, height: 500)` is expensive

**Assessment**: Elegant but requires significant adaptation for our AppKit panel.

### Option C: NSWindow + CALayer (JNWAnimatableWindow)

**Source**: [JNWAnimatableWindow](https://github.com/jwilling/JNWAnimatableWindow)

**How it works**:
1. Capture window via `CGWindowListCreateImage` (captures material blur!)
2. Force pixel materialization by redrawing into a `CGBitmapContext`
3. Place screenshot in a `CALayer` on a fullscreen transparent overlay window
4. Animate the layer with `CATransform3D` (opacity, scale, position, rotation)
5. On completion, restore original window

**Pros**:
- macOS native — the only macOS-native implementation
- Captures material blur via `CGWindowListCreateImage`
- Clean API (`orderOutWithDuration:timing:animations:`)
- Handles snapshot timing (forces pixel materialization before hiding window)

**Cons**:
- No mesh warp — only flat `CATransform3D` transforms (scale, translate, rotate)
- `CGWindowListCreateImage` is deprecated in macOS 15
- Creates fullscreen overlay window
- Objective-C, needs bridging

**Assessment**: Good snapshot/overlay pattern but lacks the genie mesh warp.

### Option D: Hybrid — JNW Snapshot + BCGenie Strips

Combine JNWAnimatableWindow's snapshot technique with BCGenieEffect's strip animation:
1. Use `CGWindowListCreateImage` to capture the panel with material blur
2. Slice into CALayer strips
3. Animate strips with BCGenieEffect's bezier math

**Pros**: Captures blur + true genie warp
**Cons**: Requires Screen Recording permission for `CGWindowListCreateImage`

---

## Deep Dive: Metal Shader via `.distortionEffect()` (Session 2 Research)

After further research, **Option B (Metal shader)** emerged as the strongest candidate. Here's the deep analysis:

### Reference Implementations Analyzed

**1. alexwidua/genie** (GitHub) — Superior implementation
- 4 independent animatable parameters: `centerX`, `progressX`, `progressY`, `translationY`
- Configurable convergence center point (not hardcoded to corner)
- Correct `maxSampleOffset: CGSize(width: 500, height: 500)` — prevents clipping
- Uses SwiftUI `Animatable` protocol with nested `AnimatablePair` for 4 floats
- Clean shader: smoothstep wave propagation, X squeeze modulated by Y position
- ~200 lines total (shader + SwiftUI wrapper)

**2. Inferno library** (twostraws/Inferno) — Simpler but limited
- Single `progress` float parameter
- Hardcoded convergence to top-right corner
- Uses `maxSampleOffset: .zero` — **clips the animation!** (pixels that move beyond bounds are lost)
- Good for simple effects but not configurable enough for menu bar targeting

### Why Metal Shader Beats All Other Options

| Concern | SpriteKit | CALayer Strips | Metal Shader |
|---------|-----------|---------------|-------------|
| White flash | Yes (platform bug) | No | No |
| Rendering pipeline | Separate (SKView) | Core Animation | Core Animation |
| GPU acceleration | Yes | No (CPU transforms) | Yes |
| Code complexity | ~200 lines + workarounds | ~400 lines bezier math | ~200 lines |
| Frame interpolation | Discrete keyframes | Discrete keyframes | Continuous (GPU) |
| macOS 14+ | Yes | Yes | Yes |
| Snapshot needed | Yes | Yes | Yes (for AppKit panel) |

### macOS-Specific Considerations

- `.distortionEffect()` works inside `NSHostingView` hosted in an overlay `NSPanel` — confirmed compatible
- `maxSampleOffset` must be large enough for the full animation displacement (~400w x 800h for panel-to-menu-bar)
- **Do NOT use `drawingGroup()`** — it breaks NSVisualEffectView vibrancy; `maxSampleOffset` is the correct approach
- Shader loaded from SPM bundle via `ShaderLibrary.bundle(.module)` — requires `.metal` file in `Resources/`
- Package.swift already has `.process("Resources")` configured

### How the Shader Works

The shader receives each pixel's position and returns where to sample from:

1. **Squeeze X** (`progressX`): Left/right edges converge toward `centerX`. The squeeze is modulated by Y position via a `smoothstep` wave — top rows squeeze first (genie funnel effect).
2. **Wave propagation** (`progressY`): Controls how far down the squeeze wave has traveled. At 0, nothing moves. At 1, the entire height is affected.
3. **Y stretch**: Compensates for horizontal compression by stretching vertically (preserves content density).
4. **Translate Y** (`translationY`): Slides the entire warped content upward toward the target point.

All 4 parameters animate from 0→1 simultaneously with ease-in-out timing over 0.5s.

### Integration Pattern for Our AppKit Panel

Since our comment input panel is AppKit (`NSPanel`), we can't apply `.distortionEffect()` directly to it. The integration works via snapshot:

1. Capture panel content via `bitmapImageRepForCachingDisplay` (same as current)
2. Convert to SwiftUI `Image`
3. Create a SwiftUI view with the image + `.distortionEffect()` modifier
4. Host in `NSHostingView` inside a transparent overlay `NSPanel`
5. Show overlay → hide original panel → animate shader params → remove overlay

This is the same overlay pattern we use with SpriteKit, but without the `SKView` first-frame bug.

---

## Session 2: Metal Shader Attempts (2026-02-23)

Five attempts using Metal shaders via SwiftUI `.distortionEffect()` all failed:

### Attempt 1: Direct port of alexwidua shader in large overlay
- Created `Genie.metal` with stitchable shader, hosted snapshot in fullscreen SwiftUI overlay with `.distortionEffect()`
- **Result**: Animation never triggered. The `rootView` mutation approach didn't propagate correctly — SwiftUI saw no state change on the `Animatable` parameters.

### Attempt 2: Fixed animation with @State + withAnimation
- Switched to `@State` float driving the shader params, triggered via `withAnimation` block
- **Result**: Animation fired but content flew sideways. The shader was NOT identity at t=0 — pixels were already displaced at the start, causing a visible jump. Convergence target was wrong (designed for bottom-corner genie, not upward toward menu bar).

### Attempt 3: Flipped shader for upward genie
- Rewrote shader math to converge toward top of screen instead of bottom-right corner
- **Result**: Still clunky trajectory. The wave propagation math assumed a specific aspect ratio and direction. Horizontal squeeze looked unnatural for an upward fly motion. Geometry mismatch between shader displacement and overlay panel positioning.

### Attempt 4: Dropped shader, simple NSPanel frame animation
- Abandoned shader entirely. Used plain `NSPanel` frame animation from panel position to menu bar icon — shrink + fly + fade.
- **Result**: Works reliably, no flash, but no mesh deformation — just a rectangular panel shrinking. This is the current fallback (what's in GenieAnimator.swift now).

### Attempt 5: Hybrid — NSPanel animation + squeeze-only shader
- Applied a horizontal-squeeze-only shader to the snapshot Image inside the moving panel, while the panel itself animated position/size via NSAnimationContext.
- **Result**: Shader distortion was not visible. The `.distortionEffect()` was clipped by the resizing panel — pixels displaced beyond the panel's shrinking bounds were lost. `maxSampleOffset` cannot help when the container itself is shrinking.

### Why Metal Shader Failed for This Use Case

The fundamental problem: `.distortionEffect()` operates within a view's bounds. For a genie effect that needs to warp content toward a distant point (menu bar), the displaced pixels extend far beyond the original view. While `maxSampleOffset` extends the sampling range, it can't extend the rendering area. A fullscreen overlay solves this but introduces complexity with animation coordination and the shader math is non-trivial to get right for an upward-and-converge trajectory (vs the original rightward-and-down that alexwidua designed for).

---

## Session 2: `presentsWithTransaction` Research (2026-02-23)

### The Discovery

`CAMetalLayer.presentsWithTransaction` is a boolean property that forces Metal drawables to present synchronously within Core Animation's commit cycle, rather than asynchronously after the next display refresh.

### Why This Should Fix the White Flash

The SKView white flash happens because:
1. SKView creates a `CAMetalLayer` for rendering
2. The first drawable is presented **asynchronously** — it schedules a presentation for the next display vsync
3. During the gap between layer creation and first drawable presentation, the `CAMetalLayer` composites as opaque white (or whatever `backgroundColor` is)
4. Core Animation renders this white frame before SpriteKit has a chance to draw transparent content

With `presentsWithTransaction = true`:
1. The drawable presentation is deferred until the current Core Animation transaction commits
2. This means SpriteKit's rendered content and the layer's visibility become atomic
3. No intermediate frame where the layer is visible but content hasn't been presented yet

### Configuration (belt-and-suspenders)

```swift
if let metalLayer = skView.layer as? CAMetalLayer {
    metalLayer.presentsWithTransaction = true  // synchronous presentation
    metalLayer.isOpaque = false                // allow transparency
    metalLayer.backgroundColor = CGColor.clear // no default fill color
}
```

All three properties work together:
- `presentsWithTransaction` — eliminates the async gap
- `isOpaque = false` — tells compositor this layer has transparency
- `backgroundColor = .clear` — ensures no fallback color shows

### Performance Impact

Negligible for this use case:
- Only affects the one-shot 0.5s animation overlay — not app-wide
- `presentsWithTransaction` adds ~1 frame of latency per render, which is imperceptible in a dismiss animation
- The SKView is created, used for one animation, and destroyed
- No sustained rendering where the synchronous presentation cost would accumulate

### Access Pattern

`SKView` uses `CAMetalLayer` as its backing layer on macOS 14+. Access via:
- `skView.layer as? CAMetalLayer` — direct cast (works if SKView's layer IS the metal layer)
- Sublayer traversal fallback — if the metal layer is nested inside a container layer

Must be set BEFORE `presentScene()` so the first frame is already in synchronous mode.

---

---

## Session 3: SpriteKit + `presentsWithTransaction` Implementation (2026-02-23)

Implemented the SpriteKit `SKWarpGeometryGrid` approach with `presentsWithTransaction` fix. Two iterations were tried.

### Attempt 1: SpriteKit warp + simultaneous NSAnimationContext panel resize

- Created full SpriteKit implementation: `SKWarpGeometryGrid` (1 col x 40 rows, 30 keyframes) with `presentsWithTransaction = true` on the `CAMetalLayer`
- Overlay panel sized to original panel frame, with `NSAnimationContext` shrinking the panel toward the target simultaneously
- **Result**: No white flash (the `presentsWithTransaction` fix worked!), but the warp deformation was completely invisible. The `NSAnimationContext` panel frame resize uniformly scaled the entire overlay (including the SKView and its contents), which visually dominated the warp. The animation looked identical to the simple shrink+fly — just a rectangular panel getting smaller.

### Attempt 2: Large overlay + SpriteKit-only actions (no panel resize)

- Removed the `NSAnimationContext` panel resize entirely
- Expanded the overlay to span from the panel position to the menu bar target (with padding)
- All movement handled by SpriteKit `SKAction.group`: warp + `SKAction.move(to:)` + `SKAction.scale(to: 0.05)` + delayed `SKAction.fadeOut`
- Warp convergence changed to pinch toward center X (0.5) since `SKAction.move` handles positioning
- **Result**: No white flash, but the warp deformation was still not perceptible. The `SKAction.scale(to: 0.05)` and `SKAction.move` dominate the visual. The mesh warp is mathematically happening (verified via debug), but at the scale and speed of the animation (0.5s, shrinking to 5%), the funnel pinch is imperceptible to the eye.

### Why the Warp Is Invisible

The fundamental issue isn't SpriteKit or the warp math — it's that the genie funnel effect is subtle geometry that gets lost when combined with aggressive scale-down and translation:

1. **Scale dominates**: Shrinking from 340x180 to ~17x9 pixels over 0.5s is a 95% reduction. At that scale, the difference between a uniformly scaled rectangle and a funnel-shaped warp is a few pixels at most.
2. **Speed**: 0.5s is fast enough that the eye tracks the overall movement trajectory, not the shape of the content.
3. **The macOS Dock genie works differently**: Apple's genie effect operates on large windows (hundreds of pixels tall) warping into a Dock icon over ~0.8s. The window stays roughly the same size during the warp phase — it deforms in place first, THEN slides into the icon. Our animation tries to do both simultaneously.

### What Would Make the Warp Visible

To get a perceptible genie effect, the animation would likely need:
- **Two phases**: First deform in place (funnel the top while bottom stays), THEN slide the funneled shape toward the target
- **Larger source**: The 340x180 panel is relatively small — less mesh resolution to work with
- **Slower timing**: At least 0.8-1.0s total to give the eye time to perceive the shape change
- **BCGenieEffect approach**: The CALayer strip-slicing (Option A) uses a two-phase bezier curve animation specifically designed for this. It's likely the only approach that would produce a visible genie effect at this scale.

### `presentsWithTransaction` Verdict

**The white flash fix works.** Setting `presentsWithTransaction = true` + `isOpaque = false` + `backgroundColor = .clear` on the `CAMetalLayer` before `presentScene()` eliminated the white first-frame flash across multiple consecutive saves. This is a confirmed fix for Apple Radar 16153326.

However, the visual quality of the warp itself wasn't distinguishable from a simple scale+move, so the added complexity of SpriteKit isn't justified.

---

## Current Status (Paused)

**The genie animation feature is on hold.** After 3 sessions, 7 SpriteKit timing fixes, 5 Metal shader attempts, and 2 SpriteKit + `presentsWithTransaction` iterations, the conclusion is:

- **White flash**: Solved via `presentsWithTransaction` (confirmed working)
- **Visible mesh warp**: Not achieved — the warp is mathematically correct but imperceptible at this panel size, animation speed, and when combined with scale+translate
- **Current state**: GenieAnimator.swift has a working SpriteKit implementation with `presentsWithTransaction`, but it looks identical to a simple shrink+fly

### What's Shipped (on the `feat/genie-animation` branch)

The branch has useful infrastructure regardless of the genie effect:
- `bounceBadge()` — menu bar icon bounce animation (works great, independent of genie)
- `useGenieAnimation` setting + Preferences toggle
- Non-genie dismiss path — subtle float-up + fade (clean, reliable)
- Deferred `@Published` state changes in dismiss flow (prevents SwiftUI re-render during animation)
- `isReleasedWhenClosed = false` fix for Preferences window crash

### If Revisiting Later

The most promising path forward is **Option A: BCGenieEffect CALayer strip slicing**. It's the only approach that:
- Uses a two-phase animation designed to make the warp visible
- Operates in Core Animation (no SpriteKit white flash)
- Is battle-tested (1400+ stars, production use)
- Would need porting from Objective-C/iOS to Swift/macOS (~400 lines)

Alternatively, accept that the simple shrink+fly animation is good enough — it's clean, reliable, has no flash, and the lack of mesh deformation is unlikely to bother users.

---

## Current File State (as of 2026-02-23)

All files in `.worktrees/genie-animation/app/RemarcPackage/Sources/RemarcFeature/`:

- `Views/GenieAnimator.swift` — SpriteKit `SKWarpGeometryGrid` + `presentsWithTransaction` (warp works but visually indistinguishable from simple scale)
- `Views/CommentInputWindowController.swift` — Modified with genie/fade branching + deferred state changes
- `AppController.swift` — Added `bounceBadge()` method
- `Services/SettingsManager.swift` — Added `useGenieAnimation` property
- `Views/PreferencesWindowController.swift` — Added toggle + `isReleasedWhenClosed = false` fix

## Other Bugs Fixed During This Work

- **Preferences crash**: `NSWindow.isReleasedWhenClosed` defaults to `true` for programmatic windows. Closing the prefs window via the close button caused AppKit to deallocate the NSWindow behind ARC, leaving a dangling pointer. Fixed with `isReleasedWhenClosed = false`.
- **Comment input sizing pop**: Panel created at fixed 340x180 but SwiftUI content had different intrinsic height. Fixed by calling `updatePanelHeight()` 50ms after showing.
- **Comment input flash on re-show**: Non-genie dismiss animated `alphaValue` to 0, but re-showing the panel before completion handler could show it at 0 opacity. Fixed by resetting `panel?.alphaValue = 1` before `makeKeyAndOrderFront`.
