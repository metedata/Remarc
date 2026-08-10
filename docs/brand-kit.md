# Remarc Brand Kit

Soft Indigo palette with jade success and amber-bronze warning accents. Designed for macOS vibrancy materials where the system provides surface backgrounds and the brand colors are used for interactive elements, status indicators, and accents.

## Brand Colors

| Token | Light | Dark | Role |
|-------|-------|------|------|
| Primary | `#6366F1` | `#A5B4FC` | Brand identity, buttons, links |
| Secondary | `#7577A0` | `#9FA0C0` | Supporting text, muted UI |
| Accent | `#8B5CF6` | `#C4B5FD` | Highlights, selections |

## Status Colors

| Token | Light | Dark | Role |
|-------|-------|------|------|
| Success | `#0D9373` | `#3DDBA6` | Confirmations, granted states |
| Warning | `#B06C18` | `#F2A94B` | Cautions, pending states |
| Error | `#DC2626` | `#F87171` | Destructive actions, failures |
| Info | `#0284C7` | `#38BDF8` | Informational, neutral status |

## Surface & Text

Not defined as Swift tokens. The app uses `NSVisualEffectView` with `.popover` material for panel backgrounds and `.primary.opacity()` for text hierarchy:

| Role | Implementation |
|------|----------------|
| Panel background | `NSVisualEffectView`, material: `.popover`, blending: `.behindWindow` |
| Primary text | `.primary` (system) |
| Secondary text | `.primary.opacity(0.6)` |
| Tertiary text | `.primary.opacity(0.45)` |
| Subtle text | `.primary.opacity(0.25)` |
| Surface tint | `Color(white: 1.0/0.0).opacity(0.015)` per color scheme |

## Gradients

| Token | Light | Dark |
|-------|-------|------|
| Brand gradient | Primary 100% → Primary 80% (top → bottom) | Same |
| Border gradient | `white @ 0.4` → `white @ 0` (top → bottom) | `white @ 0.2` → `white @ 0` |

## Swift API

All tokens are static methods on `Color` with a `remarc` prefix, taking `(for colorScheme: ColorScheme)`:

```swift
// Solid colors → Color
Color.remarcPrimary(for: colorScheme)
Color.remarcSecondary(for: colorScheme)
Color.remarcAccent(for: colorScheme)
Color.remarcSuccess(for: colorScheme)
Color.remarcWarning(for: colorScheme)
Color.remarcError(for: colorScheme)
Color.remarcInfo(for: colorScheme)

// Gradients → LinearGradient
Color.remarcBrandGradient(for: colorScheme)
Color.remarcBorderGradient(for: colorScheme)
```

Usage requires `@Environment(\.colorScheme) var colorScheme` in the view.
