# Press-and-Hold Stamp Interaction Design

## Overview

Replace the "Accept Invitation" click CTA on the Early Tester invite page with a press-and-hold circular button that makes the user feel like they're physically stamping the letter. A custom stamp cursor reinforces the metaphor from the moment the letter appears.

## Hold Button Design

### Visual
- Circular button (130x130px) embossed into the paper surface
- Background matches the letter paper color (`--paper-letter: #d8dce6`) with inset shadows creating a pressed-in effect
- Monospace font (`SF Mono` / `Fira Code` / `Cascadia Code` / `JetBrains Mono` fallback stack)
- Label: "PRESS & HOLD TO ACCEPT" (uppercase, 10.5px, color `#4a4e5a`, embossed text-shadow)
- Hint text below: "hold for 2.5s" in monospace, lighter color (`#7a7e8a`)
- Idle hover: subtle `scale(1.02)` to hint interactivity

### Progress Ring
- SVG ring stroke indicator (radius 54, stroke-width 3.5)
- Background ring: `#b8bcc8` (subtle on paper)
- Progress ring: `#4338CA` (indigo), `stroke-linecap: round`
- Fills clockwise from 12 o'clock (SVG rotated -90deg)
- Soft glow: `drop-shadow(0 0 4px rgba(99,102,241,0.4))`
- Driven by `requestAnimationFrame` loop tracking elapsed hold time

### Embossed Effect
```css
background: #cdd2de;
box-shadow:
  inset 2px 2px 6px rgba(0,0,0,0.18),
  inset -1px -1px 4px rgba(255,255,255,0.5),
  0 1px 2px rgba(255,255,255,0.4);
```
Text shadow: `0 1px 0 rgba(255,255,255,0.6)` for embossed text effect.

## Interaction States

```
envelope -> opening -> letter -> [stamp cursor activates]
                          |
                          +- idle (hold button visible, ring empty)
                          |    +- mousedown -> holding
                          |    +- hover -> subtle scale(1.02) hint
                          |
                          +- holding (ring fills 0->1 over 2.5s via rAF)
                          |    +- mouseup before 1.0 -> releasing
                          |    +- mouse leaves button -> releasing
                          |    +- progress reaches 1.0 -> complete
                          |
                          +- releasing (spring decay, ring snaps back)
                          |    +- decay reaches ~0 -> idle
                          |    +- mousedown during decay -> holding (resumes from current value)
                          |
                          +- complete
                               +- button fades & scales down (220ms)
                               +- stamp slams from above (800ms, expo easing)
                               +- stamp cursor reverts to default
                               +- continues existing flow -> transition -> reveal -> main
```

### Hold Duration
2.5 seconds from 0 to 1.0 progress.

### Spring-Back Physics (on early release)
- Formula: `progress *= e^(-decay * dt)` with `decay = 8`
- Gives a quick snap back that decelerates naturally
- When progress drops below 0.01, snap to 0 and return to idle
- If user presses down again during decay, progress resumes from current value (no reset penalty)

### Re-engagement
Pressing down while the spring is decaying resumes hold from the current progress value. This rewards persistence and feels forgiving.

## Stamp Cursor

### Asset
- Source: `assets/launch-assets/Remarc-Stamp.svg` (92x107, indigo rubber stamp with R logo)
- Convert to PNG at ~40x46px for CSS cursor compatibility (SVG cursor support is inconsistent)
- Base64-encode the PNG into a CSS rule to avoid extra network requests

### CSS Implementation
```css
.stamp-cursor {
  cursor: url(data:image/png;base64,...) 20 40, auto;
}
```
- Hotspot at center-bottom of stamp handle (20, 40) so the press point feels natural
- Fallback: `cursor: pointer`

### Lifecycle
- **Activates**: When page state enters `letter` (letter rises from envelope) - add `stamp-cursor` class to letter container
- **Deactivates**: After stamp slam animation completes - remove `stamp-cursor` class
- Implementation is pure CSS class toggling, no JS cursor management

## Stamp Slam Transition

After hold progress reaches 1.0:

### Step 1: Button Exit (220ms, ease-out)
- `opacity: 1 -> 0`, `scale: 1 -> 0.92`
- Matches existing CTA fade-out timing

### Step 2: Anticipation Pause (150ms)
- Brief gap between button disappearing and stamp landing
- Builds anticipation

### Step 3: Stamp Slams Down (800ms, expo easing)
- Easing: `cubic-bezier(0.22, 1, 0.36, 1)`
- Keyframes:
  - Start: `scale(1.5) rotate(-8deg) translateY(-60px)`, `opacity: 0`
  - 50%: `opacity: 1`
  - 75%: `scale(1.02) rotate(-3.5deg) translateY(0)` (lands)
  - 100%: `scale(1) rotate(-3deg)` (settles)
- Reuses existing stamp landing keyframes with added `translateY` for "from above" motion

### Step 4: Stamp Progress Ring (3000ms, ease-in-out)
- Existing circular SVG stroke animation plays after stamp lands
- Personalizes stamp with date and user name

### Step 5: Cursor Reverts
- Remove `stamp-cursor` class after Step 3 completes

### Step 6: Continue Existing Flow
- `transition -> reveal -> main` sequence proceeds unchanged

### Positioning
- Stamp element centered in the same container and position as the hold button
- Same parent, same centering - stamp appears exactly where the button was

## Technical Approach

**Web Animations API + rAF for spring physics**

- `requestAnimationFrame` loop drives a `0 -> 1` progress value while holding, controlling the SVG `stroke-dashoffset`
- Same rAF loop applies damped spring decay formula when released early
- Web Animations API handles the stamp slam-down (reusing existing keyframe patterns)
- CSS class toggling handles the stamp cursor

### Key Constants
| Constant | Value | Purpose |
|----------|-------|---------|
| `HOLD_DURATION` | `2500` | ms to fill ring completely |
| `SPRING_DECAY` | `8` | Damping coefficient for spring-back |
| `SNAP_THRESHOLD` | `0.01` | Progress below this snaps to 0 |
| `HOLD_RING_CIRCUMFERENCE` | `339.29` | Hold button SVG ring circumference (2 * pi * 54). Distinct from existing `STAMP_CIRCUMFERENCE` (590.62, r=94) used by the post-stamp progress ring. |
| `BUTTON_EXIT_MS` | `220` | Button fade-out duration |
| `PAUSE_MS` | `150` | Anticipation gap |
| `STAMP_SLAM_MS` | `800` | Stamp landing duration |

### Files Modified
- `website/invite/index.html` - All changes in this single file (HTML, CSS, JS are inline)

### Changes to Existing Code
- Remove `.cta-invite` button and its click handler
- Add hold button HTML (SVG ring + label) in same container position
- Add hold interaction JS (rAF loop, spring physics, state management)
- Replace the existing `waitForAccept()` promise (which resolves on CTA click) with a `waitForHoldComplete()` promise that resolves when hold progress reaches 1.0. The ceremony flow is a linear `async` function that `await`s this gate before proceeding to the stamp animation.
- Add stamp cursor CSS rule and class toggle at `letter` state entry and stamp completion
- Convert and embed `Remarc-Stamp.svg` as base64 PNG cursor

### Notes
- **Mobile**: Mobile users are redirected to a "best experienced on desktop" screen before reaching the letter state, so this interaction is desktop-only. No touch event handling needed.
- **Stamp cursor asset prep**: The SVG-to-PNG conversion and base64 encoding should be done as the first implementation step, producing a CSS data URI ready to embed.