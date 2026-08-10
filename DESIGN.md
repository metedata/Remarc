# Remarc Design Reference

Target aesthetic: **Raycast** — clean, floating panels with subtle depth and material backgrounds.

## Color System

All brand colors are defined in `Views/Colors.swift` as `Color` extensions. Use `remarc*` tokens — never hardcode hex values in views. All tokens take `colorScheme` and adapt for light/dark mode automatically.

### Brand Colors

| Token | Dark | Light |
|---|---|---|
| `remarcPrimary` | `#A5B4FC` `rgb(165, 180, 252)` | `#4338CA` `rgb(67, 56, 202)` (indigo-700) |
| `remarcSecondary` | `#9FA0C0` `rgb(159, 160, 192)` | `#7577A0` `rgb(117, 119, 160)` |
| `remarcAccent` | `#C4B5FD` `rgb(196, 181, 253)` | `#8B5CF6` `rgb(139, 92, 246)` |

### Status Colors

| Token | Dark | Light |
|---|---|---|
| `remarcSuccess` | `#3DDBA6` `rgb(61, 219, 166)` | `#0D9373` `rgb(13, 147, 115)` |
| `remarcWarning` | `#F2A94B` `rgb(242, 169, 75)` | `#B06C18` `rgb(176, 108, 24)` |
| `remarcError` | `#F87171` `rgb(248, 113, 113)` | `#DC2626` `rgb(220, 38, 38)` |
| `remarcInfo` | `#38BDF8` `rgb(56, 189, 248)` | `#0284C7` `rgb(2, 132, 199)` |

### Raw Brand Tints

For audio-reactive effects, gradients, and glow — not for standard UI elements.

| Token | Value |
|---|---|
| `remarcBrandIndigo` | `#6366F1` `Color(red: 0.388, green: 0.400, blue: 0.945)` |
| `remarcBrandViolet` | `#8B5CF6` `Color(red: 0.545, green: 0.361, blue: 0.965)` |

### Surfaces

| Token | Dark | Light |
|---|---|---|
| `remarcDropdownBackground` | `rgb(41, 41, 46)` | `rgb(250, 250, 250)` |

### Gradients

| Token | Description |
|---|---|
| `remarcBrandGradient` | Linear top-to-bottom `remarcPrimary` at 100% to 80% opacity — for primary CTA buttons |
| `remarcBorderGradient` | Linear top-to-bottom white opacity (dark: 0.2, light: 0.4) fading to clear — subtle border highlight |
| `remarcBackgroundGradient` | Layered `EllipticalGradient` wash with `.plusLighter` blend — indigo from top-left, violet from bottom-right over a darkened base. Used for popover backgrounds. Do not add `.background(.regularMaterial)` to SwiftUI — the VEV provides that |

## Design Tokens

### Corner Radii

| Element | Radius | Constant |
|---|---|---|
| Onboarding window | `16pt` (`.continuous`) | `AppConstants.onboardingCornerRadius` |
| Panel / expanded view | `12pt` (`.continuous`) | `AppConstants.panelCornerRadius` |
| Cards | `10pt` (`.continuous`) | `AppConstants.cardCornerRadius` |
| Tooltips | `8pt` | `AppConstants.tooltipCornerRadius` |
| Buttons, dropdowns, inputs | `6pt` | Hardcoded |
| Quote border corners | `1-2pt` | — |

### Shadows (SwiftUI, NOT `panel.hasShadow`)

Layered double-shadow pattern for premium depth.

**Expanded panel / comment input:**
```swift
.shadow(color: .black.opacity(0.12), radius: 16, y: 8)
.shadow(color: .black.opacity(0.06), radius: 3, y: 1)
```

**Cards (resting / hover):**
```swift
// Resting
.shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 6, y: 3)
.shadow(color: .black.opacity(colorScheme == .dark ? 0.15 : 0.03), radius: 1, y: 1)

// Hover
.shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.14), radius: 12, y: 6)
.shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.05), radius: 2, y: 2)
```

**Toast:**
```swift
.shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 12, y: 6)
.shadow(color: .black.opacity(0.08), radius: 2, y: 1)
```

**Selection tooltip:**
```swift
.shadow(color: .black.opacity(0.08), radius: 6, y: 3)
.shadow(color: .black.opacity(0.03), radius: 1, y: 1)
```

**Floating action button (resting / hover):**
```swift
.shadow(color: Color.remarcPrimary(for:).opacity(isHovered ? 0.4 : 0.25),
        radius: isHovered ? 6 : 4, y: isHovered ? 3 : 2)
```

### Borders

Ultra-thin, adaptive to color scheme. Standard pattern: `0.5pt` lineWidth with colorScheme-aware opacity.

```swift
// Standard border color
colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)

// Application (inset variant — panels)
.overlay(
    RoundedRectangle(cornerRadius: radius, style: .continuous)
        .inset(by: 0.5).stroke(borderColor, lineWidth: 0.5)
)

// Application (strokeBorder variant — cards, pills)
.background {
    Shape().strokeBorder(borderColor, lineWidth: 0.5)
}
```

Toast uses slightly higher dark-mode opacity (`0.15` vs `0.12`).

### Quote Border

2pt indigo left border for reference content (text quotes, screenshots, web elements, attachments). Applied via the `.quoteBorder()` modifier defined in `Colors.swift`.

```swift
// Usage
referenceContent
    .quoteBorder()

// Renders as
.overlay(alignment: .leading) {
    RoundedRectangle(cornerRadius: 1)
        .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
        .frame(width: 2)
}
```

### Edge Refraction

`EdgeRefractionModifier` renders a subtle colored glow along a card's rounded corner edge — as if a nearby colored element casts light that refracts along the border. Uses a trimmed, blurred stroke clipped inward and masked with a radial gradient.

```swift
.modifier(EdgeRefractionModifier(
    color: statusColor,
    corner: .topTrailing,
    cornerRadius: 10,
    intensity: 1.0,  // opacity multiplier
    spread: 65       // how far the glow extends
))
```

### Materials

| Element | Material |
|---|---|
| Main popover | `.popover` (NSVisualEffectView) |
| Expanded panel / comment input | `.regularMaterial` |
| Onboarding | `.regularMaterial` |
| Selection tooltip | `.regularMaterial` |
| Toast | `.thinMaterial` |
| Dictation pill | `.ultraThinMaterial` |

### Spacing (8pt grid)

| Token | Value |
|---|---|
| XS | `4pt` |
| S | `6pt` |
| SM | `8pt` |
| M | `12pt` |
| L | `16pt` |
| XL | `24pt` |

### Typography (SF Pro via `.system()`)

| Element | Size | Weight |
|---|---|---|
| Body text | `13pt` | `.regular` |
| Card header | `12pt` | `.semibold` |
| Secondary / metadata | `11pt` | `.regular` |
| Pill widget text | `11pt` | `.medium` |
| Tiny labels | `10pt` | `.regular` |
| Buttons / inputs | `13pt` | `.medium` |
| Section headers | `14pt` | `.semibold` |
| Headlines | `18-24pt` | `.semibold` |
| Monospaced (paths, IDs) | `10-13pt` | `.monospaced` |

### Animation

**Spring animations** (preferred for interactive elements):
```swift
// Standard interactive spring (buttons, hovers)
.spring(response: 0.3, dampingFraction: 0.6)

// Snappy spring (cards, history)
.spring(response: 0.3, dampingFraction: 0.7)

// Tight spring (session bar, status dots)
.spring(response: 0.3, dampingFraction: 0.85)

// Bouncy spring (voice input save)
.spring(response: 0.3, dampingFraction: 0.4)
```

**Ease curves:**
```swift
// Quick interactions (dropdown hovers, fast dismiss)
.easeInOut(duration: 0.1)  /  .easeOut(duration: 0.1)

// Standard UI transitions (hover states, button effects)
.easeInOut(duration: 0.15)

// Content transitions
.easeInOut(duration: 0.2)

// State changes (recording, dictation)
.easeInOut(duration: 0.3)
```

**NSAnimationContext (AppKit panels):**
```swift
// Quick dismiss
context.duration = 0.12
context.timingFunction = CAMediaTimingFunction(name: .easeIn)

// Panel frame resize, tooltip fade
context.duration = 0.15
context.timingFunction = CAMediaTimingFunction(name: .easeOut)

// Panel alpha fade
context.duration = 0.3
context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
```

### NSPanel Configuration

Base configuration for all floating panels:
```swift
panel.level = .floating
panel.backgroundColor = .clear
panel.isOpaque = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.animationBehavior = .utilityWindow
```

`hasShadow` varies by panel type:

| Panel | `hasShadow` | `level` | Notes |
|---|---|---|---|
| Selection tooltip | `false` | `.floating` | Uses SwiftUI shadows |
| Screenshot overlay | `false` | `.screenSaver + 2` | Border-only panel |
| Menu bar popover | `true` | `.popUpMenu` | Shadow follows VEV mask shape |
| Comment input editor | `true` | `.floating` | — |
| Dictation pill | `true` | `.floating` | — |
| Screenshot preview | `true` | `.popUpMenu + 3` | Above other panels |
| Onboarding | `true` | `.floating` | Movable by background |
| Floating editor | `true` | `.floating` | `animationBehavior = .none` |
| Dropdown | `true` | — | — |

## Components

Reusable views live in `Views/`. Use them instead of inlining styles. Each entry lists purpose, key specs, and the file where it's defined.

### Buttons

#### Footer buttons (popover bottom bar)

| Variant | Style at rest | Used for | Defined in |
|---|---|---|---|
| Primary | Filled (white at low opacity), `remarcPrimary` icon/text | Main footer action. Currently Copy All | `PopoverContentView.swift` `primaryFooterButton` + `FooterButtonStyle` |
| Secondary | Outline only (`0.5pt` stroke, no fill), `remarcPrimary` icon/text | Status surface or less prominent action. Currently MCP | `PopoverContentView.swift` `SecondaryFooterButtonStyle` |
| Icon | Icon-only, transparent at rest, white fill + `remarcPrimary` tint on hover | Compact actions: Resolve All, Delete All, Export, Settings | `PopoverContentView.swift` `iconFooterButton` + `HoverTintButton` |

Shared specs:

| Spec | Value |
|---|---|
| Font (text variants) | `11pt .medium` |
| Symbol size (icon-only) | `12pt` |
| Padding (text variants) | `10pt` horizontal × `5pt` vertical |
| Frame (icon-only) | `26pt × 26pt` |
| Corner radius | `5pt .continuous` |
| Hover fill (text variants) | `white.opacity(0.08)` dark / `white.opacity(0.55)` light |
| Press feedback | `opacity(0.7)` |
| Animation | `.easeInOut(duration: 0.15)` |

Secondary variant border (visible at rest):

| Mode | Color |
|---|---|
| Dark | `white.opacity(0.12)` |
| Light | `black.opacity(0.08)` |

`0.5pt` `strokeBorder`, matching the standard border pattern in [Borders](#borders). Supports a status-indicator-dot overlay (see [Status Indicators](#status-indicators)) for surfacing live state without forcing a click.

#### Other button components

| Component | Purpose | Defined in |
|---|---|---|
| `FloatingActionButton` / `BrandCTAButtonStyle` | Primary brand CTA on a brand gradient (capsule or rounded rect) | `Views/FloatingActionButton.swift` |
| `CreationHeaderButton` | `28×28pt` circular icon button used in the panel header | `Views/FloatingActionButton.swift` |
| `ExpandingCTAButton` | Capsule icon that expands on hover to reveal a label. Roles: `.neutral`, `.destructive`, `.accent` | `Views/ExpandingCTAButton.swift` |
| `ConfirmationButton` | Tri-role confirm bar. Roles: `.cancel` (outlined), `.destructive` (red), `.confirm` (green) | `Views/ConfirmationButton.swift` |
| `HoverTintButton` | Generic icon-only button with foreground tint change on hover | `Views/PopoverContentView.swift` |

### Status Indicators

#### Status dot

A `6-7pt` filled circle that signals state. Always uses a status token (`remarcSuccess`, `remarcWarning`, `remarcError`, `remarcInfo`). Add a soft radial glow when the state is active or positive.

```swift
Circle()
    .fill(statusColor)
    .frame(width: 6, height: 6)
    .shadow(color: isActive ? statusColor.opacity(0.6) : .clear, radius: 3)
```

Variants in use:

| Use | Placement | Size | Defined in |
|---|---|---|---|
| MCP status badge | Overlay `.topTrailing` on the MCP footer button, `offset(x: 2, y: -2)` | `6pt` | `PopoverContentView.swift` `mcpButton` |
| MCP popover header | Inline with status label inside the MCP popover | `6pt` | `PopoverContentView.swift` `mcpPopoverContent` |
| Comment status pill | Inside a capsule that expands to a label on hover | `7pt` | `Views/StatusDotView.swift` |

State to color mapping (MCP specifically):

| State | Token | Visual |
|---|---|---|
| Connected (`isEnabled`) | `remarcSuccess` | Green dot with glow |
| Needs attention (`hasDependencyError`) | `remarcWarning` | Orange dot |
| Disconnected (neither) | `remarcError` | Red dot |

Animation: `.easeInOut(duration: 0.2)` on color change. When the dot is inside a control that expands or moves, use the tight spring `.spring(response: 0.3, dampingFraction: 0.85)`.
