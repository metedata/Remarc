# Crit Mode Recording View Improvements — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the Crit Mode recording view more responsive, visually polished, and on-brand with audio-reactive effects and a custom R logo loading animation.

**Architecture:** Four independent improvements to the existing recording view. The waveform sensitivity and stop button are trivial edits. The audio-reactive background adds smoothed level tracking to `CritModeService` and two gradient layers to the recording view. The R logo loading animation is a new SwiftUI `Shape` + `.trim()` view replacing `ProgressView`.

**Tech Stack:** SwiftUI Canvas, SwiftUI Shape/Path with `.trim()` animation, existing `CritModeService` + `AudioWaveformView`.

**Design doc:** `docs/plans/2026-03-05-crit-mode-recording-improvements-design.md`

---

### Task 1: Waveform Sensitivity Curve

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/AudioWaveformView.swift:43`

**Step 1: Update normalization in `drawWaveform()`**

In `AudioWaveformView.swift`, find the normalization line (line ~43):

```swift
// BEFORE:
let normalized = min(max(CGFloat(level) * 8, 0.05), 1.0)

// AFTER:
let scaled = min(max(CGFloat(level) * 16, 0.0), 1.0)
let normalized = max(pow(scaled, 0.6), 0.05)
```

The `* 16` doubles the base sensitivity. `pow(x, 0.6)` compresses quiet sounds upward (logarithmic feel). The `max(..., 0.05)` ensures silent bars still show a minimum pip.

**Step 2: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
bash scripts/relaunch.sh
```

Verify: Start Crit Mode, speak at normal volume. Bars should visibly respond to quiet speech and fill ~60-70% during normal talking.

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/AudioWaveformView.swift
git commit -m "feat(crit): increase waveform sensitivity with power curve"
```

---

### Task 2: Center the Stop Button

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift:66-84`

**Step 1: Replace the bottom-right HStack layout**

In `CritModeRecordingView.swift`, find `recordingContent(startTime:)` (line ~51). Replace the bottom portion (the `HStack` with `Spacer()` + `FloatingActionButton`) with a centered button:

```swift
// BEFORE (lines 68-84):
HStack {
    Spacer()
    FloatingActionButton(icon: "stop.fill") {
        Task {
            do {
                let comments = try await service.stopRecording()
                onComplete(comments)
            } catch {
                debugLog("CritModeRecordingView: Stop failed: \(error)")
                onCancel()
            }
        }
    }
    .help("Stop recording")
}
.padding(.trailing, 14)
.padding(.bottom, 14)

// AFTER:
FloatingActionButton(icon: "stop.fill") {
    Task {
        do {
            let comments = try await service.stopRecording()
            onComplete(comments)
        } catch {
            debugLog("CritModeRecordingView: Stop failed: \(error)")
            onCancel()
        }
    }
}
.help("Stop recording")
.padding(.bottom, 14)
```

The button is already in the parent `VStack` which centers by default. Removing the `HStack`/`Spacer()` wrapper centers it.

**Step 2: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
bash scripts/relaunch.sh
```

Verify: Stop button should now be horizontally centered at the bottom.

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift
git commit -m "feat(crit): center stop button horizontally"
```

---

### Task 3: Add Smoothed Audio Levels to CritModeService

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/CritModeService.swift`

**Step 1: Add published smoothed level properties**

After the existing `@Published var audioLevels: [Float] = []` (line ~93), add:

```swift
@Published var smoothedLevel: Float = 0
@Published var slowSmoothedLevel: Float = 0
```

**Step 2: Update `drainCollector()` to compute smoothed levels**

In `drainCollector()` (line ~198), after the existing for-loop that appends levels, add smoothing:

```swift
private func drainCollector() {
    guard let engine = captureEngine else { return }
    let pending = engine.drain()
    var latestRMS: Float = 0
    for (rms, buffer) in pending {
        appendLevel(rms)
        recordedBuffers.append(buffer)
        latestRMS = rms
    }
    // Smooth audio levels for visual effects
    if !pending.isEmpty {
        smoothedLevel = smoothedLevel * 0.85 + latestRMS * 0.15
        slowSmoothedLevel = slowSmoothedLevel * 0.95 + latestRMS * 0.05
    }
}
```

**Step 3: Reset smoothed levels in `cancelRecording()` and at recording start**

In `startRecording()`, after `self.audioLevels = []` (line ~111), add:

```swift
self.smoothedLevel = 0
self.slowSmoothedLevel = 0
```

In `cancelRecording()` (line ~163), after `audioLevels = []`, add:

```swift
smoothedLevel = 0
slowSmoothedLevel = 0
```

**Step 4: Build**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
```

Should compile cleanly. No visual change yet.

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/CritModeService.swift
git commit -m "feat(crit): add smoothed audio level properties for visual effects"
```

---

### Task 4: Audio-Reactive Background Effects

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift`

**Step 1: Add the waveform aura glow underlay**

In `recordingContent(startTime:)`, wrap the `AudioWaveformView` in a `ZStack` with a radial gradient behind it:

```swift
// Replace the standalone AudioWaveformView + padding with:
ZStack {
    // Aura glow - reacts to audio level
    let glowIntensity = CGFloat(service.smoothedLevel) * 10
    let clampedGlow = min(max(glowIntensity, 0.0), 1.0)

    RadialGradient(
        colors: [
            Color.remarcPrimary(for: colorScheme).opacity(0.25 * clampedGlow),
            Color.remarcAccent(for: colorScheme).opacity(0.15 * clampedGlow),
            Color.clear
        ],
        center: .center,
        startRadius: 5,
        endRadius: 60 + 80 * clampedGlow
    )
    .frame(height: 120)
    .blur(radius: 20)
    .animation(.easeOut(duration: 0.15), value: clampedGlow)

    AudioWaveformView(levels: service.audioLevels)
}
.padding(.horizontal, 24)
```

**Step 2: Add the background breathing overlay**

Add a background modifier to the recording content's outer container. At the top of `recordingContent()`, before the `VStack`, create a computed breathing opacity:

```swift
private func recordingContent(startTime: Date) -> some View {
    let breathIntensity = CGFloat(service.slowSmoothedLevel) * 8
    let breathClamped = min(max(breathIntensity, 0.0), 1.0)
    let breathOpacity = 0.8 + 0.6 * breathClamped  // 0.8 to 1.4 range

    return VStack(spacing: 0) {
        // ... existing content ...
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
        // Breathing background - modulates existing gradient pattern
        let op = colorScheme == .dark ? 0.18 : 0.13
        let breathOp = op * breathOpacity

        Color.clear
            .overlay(
                EllipticalGradient(
                    colors: [Color(red: 0.388, green: 0.400, blue: 0.945).opacity(breathOp * 1.4), .clear],
                    center: .topLeading,
                    startRadiusFraction: 0.0,
                    endRadiusFraction: 1.0
                )
                .blendMode(.plusLighter)
            )
            .overlay(
                EllipticalGradient(
                    colors: [Color(red: 0.545, green: 0.361, blue: 0.965).opacity(breathOp * 0.6), .clear],
                    center: .bottomTrailing,
                    startRadiusFraction: 0.0,
                    endRadiusFraction: 0.7
                )
                .blendMode(.plusLighter)
            )
            .animation(.easeInOut(duration: 0.5), value: breathClamped)
    }
}
```

Note: The `return` keyword is needed because the local `let` bindings make the implicit return ambiguous.

**Step 3: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
bash scripts/relaunch.sh
```

Verify: During recording, a soft indigo/violet glow should pulse behind the waveform bars when speaking. The panel background should subtly breathe. Both should be calm during silence.

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift
git commit -m "feat(crit): add audio-reactive aura glow and breathing background"
```

---

### Task 5: Create RemarcLogoLoadingView — R Shape Path

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/RemarcLogoLoadingView.swift`

**Step 1: Create the file with the R logo shape**

The SVG paths come from `assets/teaser-v2.html`. The outer body path has a `translate(123,100)` offset in the SVG; we normalize all paths to a 0-1 coordinate space relative to the bounding box.

The outer body path in SVG coordinates (after applying translate(123,100)):
- `d="M452.273 56C590.738 56 702.987 168.249 702.987 306.714C702.987 409.13 641.538 497.113 553.532 536.031L427.549 570.401C421.841 562.363 412.491 557.429 402.632 557.429H317.666C310.17 557.429 302.938 560.199 297.36 565.209L80 760.422V200.351C80 120.628 144.628 56 224.351 56H452.273Z"`

The inner bowl (translate(173,152) relative to parent, so translate(296,252) absolute):
- `d="M40.185 0C17.992 0 0 17.992 0 40.185V380L48.505 336.363C70.642 316.44 99.375 305.407 129.158 305.407H281.296C365.632 305.407 434 237.04 434 152.704S365.632 0 281.296 0H40.185Z"`

The leg:
- `d="M553.532 536.031C622.091 646.898 692.824 703.102 767.565 744.604C775.975 749.274 772.704 762.54 763.084 762.499C576.277 761.703 573.236 775.542 427.549 570.401Z"`

Create the file:

```swift
import SwiftUI

// MARK: - R Logo Shape (for stroke-draw animation)

/// The Remarc "R" letterform as a SwiftUI Shape, suitable for .trim() animation.
/// Derived from assets/teaser-v2.html SVG paths (1024x1024 viewBox, translate(123,100)).
@available(macOS 26, *)
struct RemarcLogoShape: Shape {
    /// Which sub-path to render
    enum Part {
        case body    // outer R shape
        case bowl    // inner counter
        case leg     // diagonal kick
    }

    let part: Part

    func path(in rect: CGRect) -> Path {
        // Original SVG coordinate space: paths drawn within ~80,56 to ~768,762
        // We scale to fit the given rect
        let svgWidth: CGFloat = 688  // 768 - 80
        let svgHeight: CGFloat = 720 // 776 - 56 (with some margin for leg)
        let scale = min(rect.width / svgWidth, rect.height / svgHeight)
        let offsetX = rect.midX - (svgWidth * scale) / 2
        let offsetY = rect.midY - (svgHeight * scale) / 2

        var path = Path()

        switch part {
        case .body:
            addBodyPath(&path, scale: scale, offsetX: offsetX, offsetY: offsetY)
        case .bowl:
            addBowlPath(&path, scale: scale, offsetX: offsetX, offsetY: offsetY)
        case .leg:
            addLegPath(&path, scale: scale, offsetX: offsetX, offsetY: offsetY)
        }

        return path
    }

    // SVG coordinates are relative to the translate(123,100) group origin.
    // We subtract the min x/y (80, 56) to normalize to 0,0 origin.

    private func addBodyPath(_ path: inout Path, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - 80) * scale + offsetX, y: (y - 56) * scale + offsetY)
        }
        path.move(to: p(452.273, 56))
        path.addCurve(to: p(702.987, 306.714), control1: p(590.738, 56), control2: p(702.987, 168.249))
        path.addCurve(to: p(553.532, 536.031), control1: p(702.987, 409.13), control2: p(641.538, 497.113))
        path.addLine(to: p(427.549, 570.401))
        path.addCurve(to: p(402.632, 557.429), control1: p(421.841, 562.363), control2: p(412.491, 557.429))
        path.addLine(to: p(317.666, 557.429))
        path.addCurve(to: p(297.36, 565.209), control1: p(310.17, 557.429), control2: p(302.938, 560.199))
        path.addLine(to: p(80, 760.422))
        path.addLine(to: p(80, 200.351))
        path.addCurve(to: p(224.351, 56), control1: p(80, 120.628), control2: p(144.628, 56))
        path.closeSubpath()
    }

    private func addBowlPath(_ path: inout Path, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        // Bowl origin in absolute SVG: translate(296,252) -> relative to our 0,0: (296-80, 252-56) = (216, 196)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x + 216) * scale + offsetX, y: (y + 196) * scale + offsetY)
        }
        path.move(to: p(40.185, 0))
        path.addCurve(to: p(0, 40.185), control1: p(17.992, 0), control2: p(0, 17.992))
        path.addLine(to: p(0, 380))
        path.addLine(to: p(48.505, 336.363))
        path.addCurve(to: p(129.158, 305.407), control1: p(70.642, 316.44), control2: p(99.375, 305.407))
        path.addLine(to: p(281.296, 305.407))
        path.addCurve(to: p(434, 152.704), control1: p(365.632, 305.407), control2: p(434, 237.04))
        // S command: smooth curve. S365.632 0 281.296 0
        // Previous control point reflected: (434, 152.704) with prev ctrl2 (434, 237.04)
        // Reflected ctrl1 = (434, 68.368)
        path.addCurve(to: p(281.296, 0), control1: p(434, 68.368), control2: p(365.632, 0))
        path.closeSubpath()
    }

    private func addLegPath(_ path: inout Path, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - 80) * scale + offsetX, y: (y - 56) * scale + offsetY)
        }
        path.move(to: p(553.532, 536.031))
        path.addCurve(to: p(767.565, 744.604), control1: p(622.091, 646.898), control2: p(692.824, 703.102))
        path.addCurve(to: p(763.084, 762.499), control1: p(775.975, 749.274), control2: p(772.704, 762.54))
        path.addCurve(to: p(427.549, 570.401), control1: p(576.277, 761.703), control2: p(573.236, 775.542))
        path.closeSubpath()
    }
}

// MARK: - Loading View

@available(macOS 26, *)
struct RemarcLogoLoadingView: View {
    enum Mode {
        case preparing   // loops stroke draw
        case processing  // draws once, then fills
    }

    let mode: Mode

    @Environment(\.colorScheme) private var colorScheme
    @State private var strokeProgress: CGFloat = 0
    @State private var showFill: Bool = false
    @State private var loopID = UUID()

    private let strokeGradient = LinearGradient(
        colors: [
            Color(red: 0.835, green: 0.773, blue: 0.976),  // #D5C5F9
            Color(red: 0.655, green: 0.549, blue: 0.992)   // #A78BFD
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    private let fillGradient = LinearGradient(
        colors: [
            Color(red: 0.655, green: 0.549, blue: 0.992),  // #A78BFD
            Color(red: 0.388, green: 0.400, blue: 0.945)   // #6366F1
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                // Glow layer (blurred copy of stroke)
                strokeLayer
                    .blur(radius: 6)
                    .opacity(0.3)

                // Main stroke
                strokeLayer

                // Fill (for processing mode completion)
                if showFill {
                    fillLayer
                        .transition(.opacity)
                }
            }
            .frame(width: 52, height: 52)

            Text(mode == .preparing ? "Preparing..." : "Turning speech into comments...")
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startAnimation() }
        .onChange(of: mode) { startAnimation() }
    }

    private var strokeLayer: some View {
        ZStack {
            RemarcLogoShape(part: .body)
                .trim(from: 0, to: strokeProgress)
                .stroke(strokeGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            RemarcLogoShape(part: .bowl)
                .trim(from: 0, to: strokeProgress)
                .stroke(strokeGradient, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            RemarcLogoShape(part: .leg)
                .trim(from: 0, to: max(strokeProgress - 0.7, 0) / 0.3)
                .stroke(strokeGradient, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private var fillLayer: some View {
        ZStack {
            RemarcLogoShape(part: .body)
                .fill(fillGradient)
            RemarcLogoShape(part: .leg)
                .fill(fillGradient)
        }
    }

    private func startAnimation() {
        strokeProgress = 0
        showFill = false

        switch mode {
        case .preparing:
            loopStrokeDraw()
        case .processing:
            withAnimation(.easeInOut(duration: 2.0)) {
                strokeProgress = 1.0
            }
            // After stroke completes, cross-fade to fill
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    showFill = true
                }
            }
        }
    }

    private func loopStrokeDraw() {
        let currentID = UUID()
        loopID = currentID

        withAnimation(.easeInOut(duration: 2.0)) {
            strokeProgress = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard loopID == currentID else { return }
            strokeProgress = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard loopID == currentID else { return }
                loopStrokeDraw()
            }
        }
    }
}
```

**Step 2: Build**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
```

Fix any compilation issues. The shape math may need adjustment — the key thing is it compiles and the paths render something recognizable.

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/RemarcLogoLoadingView.swift
git commit -m "feat(crit): add RemarcLogoLoadingView with R stroke-draw animation"
```

---

### Task 6: Wire Loading Views into CritModeRecordingView

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift`

**Step 1: Replace `preparingView` with `RemarcLogoLoadingView`**

```swift
// BEFORE (lines 36-47):
private var preparingView: some View {
    VStack(spacing: 12) {
        Spacer()
        ProgressView()
            .scaleEffect(0.8)
        Text("Preparing...")
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.6))
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

// AFTER:
private var preparingView: some View {
    RemarcLogoLoadingView(mode: .preparing)
}
```

**Step 2: Replace `processingView` with `RemarcLogoLoadingView`**

```swift
// BEFORE (lines 91-102):
private var processingView: some View {
    VStack(spacing: 12) {
        Spacer()
        ProgressView()
            .scaleEffect(0.8)
        Text("Processing...")
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.6))
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

// AFTER:
private var processingView: some View {
    RemarcLogoLoadingView(mode: .processing)
}
```

**Step 3: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
bash scripts/relaunch.sh
```

Verify:
- Start Crit Mode: should see the R logo stroke drawing in a loop during "Preparing..."
- Stop recording: should see the R stroke draw once then fill in during "Turning speech into comments..."

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift
git commit -m "feat(crit): wire RemarcLogoLoadingView into preparing and processing states"
```

---

### Task 7: Visual Polish and Tuning

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/RemarcLogoLoadingView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CritModeRecordingView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/AudioWaveformView.swift`

**Step 1: Tune values after visual testing**

This is a polish pass. After testing the build from Task 6, adjust:

- **R logo size**: The `frame(width: 52, height: 52)` may need adjustment. Try 48-64pt range.
- **Stroke width**: The 2pt/1.5pt strokes may be too thin or thick at the rendered size.
- **Glow blur**: The `blur(radius: 6)` and `opacity(0.3)` on the glow layer.
- **Loop timing**: The 2.0s draw + 0.3s pause + 2.2s delay cycle may feel too fast or slow.
- **Aura glow**: The `* 10` multiplier, gradient radii, and blur radius in the aura effect.
- **Background breathing**: The `* 8` multiplier and opacity range (0.8-1.4).
- **Waveform sensitivity**: The `* 16` multiplier and `pow(x, 0.6)` exponent.

Make adjustments based on visual testing.

**Step 2: Build and relaunch**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
bash scripts/relaunch.sh
```

**Step 3: Commit**

```bash
git add -A
git commit -m "feat(crit): tune visual parameters for recording view improvements"
```
