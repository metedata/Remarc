# Crit Mode Recording View Improvements — Design

Date: 2026-03-05

## Summary

Four improvements to the Crit Mode recording view: more responsive waveform, audio-reactive background effects, branded loading states using the R logo stroke-draw animation, and centered stop button.

## 1. Waveform Sensitivity

Replace the linear `* 8` multiplier in `AudioWaveformView.drawWaveform()` with a higher base multiplier and a power curve:

```swift
let scaled = min(max(CGFloat(level) * 16, 0.05), 1.0)
let normalized = pow(scaled, 0.6)
```

The `pow(x, 0.6)` curve compresses quiet sounds upward:
- Quiet speech (RMS ~0.02): barely visible -> ~35% bar height
- Normal speech (RMS ~0.05): ~40% -> ~65% bar height
- Loud peaks still max out naturally

Single-line change in `AudioWaveformView`.

## 2. Stop Button Centered

Move `FloatingActionButton` from bottom-right (`HStack` + `Spacer()` + trailing padding) to horizontally centered at the bottom of the recording `VStack`, below the hint text.

## 3. Audio-Reactive Background Effects

Both layers driven by an exponential moving average of the current RMS level, updated at the existing 30fps drain timer rate.

### Layer A: Waveform Aura Glow

- `RadialGradient` (indigo -> violet -> clear) centered behind `AudioWaveformView`
- Radius and opacity animate with smoothed audio level
- Quiet: small radius, dim. Speaking: expands and brightens
- Implemented as an underlay in `recordingContent()` behind the waveform

### Layer B: Background Breathing

- The `remarcBackgroundGradient` elliptical gradient opacities modulated by a very slow-smoothed audio level
- Subtle shift: indigo/violet overlays breathe between `op * 0.8` and `op * 1.4`
- Lives in the recording content area only (not shared by other states)

### Audio Level Smoothing

Add a `@Published var smoothedLevel: Float` to `CritModeService`, updated in `drainCollector()`:

```swift
smoothedLevel = smoothedLevel * 0.85 + currentRMS * 0.15  // fast response
```

For the background breathing, a second slower smoother:
```swift
slowSmoothedLevel = slowSmoothedLevel * 0.95 + currentRMS * 0.05
```

## 4. Branded Loading States (R Logo Animation)

### New file: `RemarcLogoLoadingView.swift`

#### R Shape as SwiftUI Path

Convert the SVG path data from `assets/Icon-Components/R-shape.svg` and `assets/teaser-v2.html` into a SwiftUI `Shape`. Three sub-paths:
- **Outer body**: The main R letterform (body + bowl cutout, even-odd rule)
- **Inner bowl**: The enclosed counter shape
- **Leg**: The diagonal kick extending from the junction

Use `pathLength` normalization so `.trim(from:to:)` works uniformly across all sub-paths.

#### Preparing State (Looping)

- R stroke draws itself: `.trim(from: 0, to: progress)` where `progress` animates 0 -> 1 over ~2s with `.easeInOut`, resets, repeats
- Brand gradient stroke: `#D5C5F9` -> `#A78BFD` (matches teaser `stroke-grad`)
- Soft glow behind: blurred duplicate at lower opacity
- Text: "Preparing..." centered below
- Logo size: ~48pt tall, centered in view
- Replaces current `ProgressView()` + "Preparing..." layout

#### Processing State (Draw Once + Fill)

- Same stroke draw animation plays once (0 -> 1), no loop
- On completion, cross-fade stroke -> fill with brand gradient (`#A78BFD` -> `#6366F1`)
- Fill holds steady while processing continues
- Text: "Turning speech into comments..." centered below
- Replaces current `ProgressView()` + "Processing..." layout

#### Runtime: Native SwiftUI

- `Shape` protocol + `.trim()` + `withAnimation` — zero dependencies
- Glow: blurred copy of the stroked shape behind at ~0.3 opacity
- No Lottie or external animation libraries needed

## Files Modified

- `AudioWaveformView.swift` — sensitivity curve change
- `CritModeRecordingView.swift` — centered stop button, background effects, new loading states
- `CritModeService.swift` — add `smoothedLevel` / `slowSmoothedLevel` published properties

## Files Created

- `RemarcLogoLoadingView.swift` — R logo Shape + stroke/fill animation view
