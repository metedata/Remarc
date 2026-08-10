# Envelope Animation Handoff

## What We Built

Merged the Codex envelope animation with the original invite-page branch:

- **Codex animation** (letter shape, letter rising from envelope, staging system, configureStage metrics) → kept
- **Original main page** (video placeholder, feedback icons, download section) → kept, not Codex's YouTube embed
- **Paper texture** from original (SVG feTurbulence filter) → added subtly to env-back and letter-card
- **Removed problematic Codex elements**: env-mouth, env-shadow, env-inner-cover, env-letter-preview (all created visual artifacts)
- **Added** simple env-inner-shadow gradient (fades in via CSS data-state when envelope opens)

## What Works

- Letter card shape and content
- Letter rising out of envelope (two-phase: peek, then full rise)
- Wax seal break animation
- Accept → stamp animation (slowed to 800ms, straightened, removed overlapping r=90 circle, enlarged logo with emboss filter)
- Transition to main page
- Replay functionality
- Mobile gate
- Debug mode (?debug)
- Paper noise texture on envelope and letter

## What's Still Broken: The Flap Animation

The top flap of the envelope doesn't animate correctly. The desired behavior: the triangular flap (flat edge at top, tip pointing down) should visually "open" - the front face shrinks toward the fold line, then the inner surface appears.

### Approaches Tried

**1. 3D rotateX with transform-origin: 50% 0% (top) - Codex's original approach**
- `.envelope` has `perspective: 800px` and `transform-style: preserve-3d`
- Flap at `transform-origin: 50% 0%`, animated `rotateX(-170deg)`
- **Result**: Flap rotates around the flat top edge. At -170deg, the backface ends up ABOVE the envelope as a floating disconnected triangle. The hinge point being at the very top of the envelope means the 58%-height flap swings up and over, creating a huge shape above.

**2. 3D rotateX with transform-origin: 50% 100% (bottom)**
- Hinge at the bottom of the flap element (58% of envelope height)
- **Result**: The hinge is visually in the MIDDLE of the envelope body, not at a natural fold line. Looks like the envelope splits in half.

**3. Positive rotateX(180deg) with transform-origin: top**
- Per working reference (smartinfogl.com), positive rotation makes the tip lift toward the viewer
- **Result**: Same floating triangle issue - at 180deg the flap ends up above the envelope, just via a different rotation path.

**4. rotateX(-95deg) with transform-origin: top**
- Stop at edge-on angle where flap is invisible, then swap to static shape
- **Result**: Flap just disappears (no visible "opening" motion), then a different shape pops in. Doesn't read as an envelope opening.

**5. 2D scaleY simulation (current approach)**
- Phase 1: `scaleY(1)` → `scaleY(0)` with `transform-origin: 50% 0%` (shrinks bottom-to-top)
- Phase 2: static `env-flap-open` triangle (tip UP) fades in behind pocket-front
- **Result**: The shrink phase works OK visually. But the open state is underwhelming - the env-flap-open is a small subtle shape behind the pocket-front V-notch. It doesn't clearly read as "envelope is open." The letter emergence still works fine though.

### Root Cause Analysis

The 3D approach fails because:
1. The `.envelope` element has `transform: translateX(-50%)`, `perspective`, and `transform-style: preserve-3d` all on the same element. This may be flattening the 3D context in practice.
2. The flap is 58% of envelope height - too large for a full rotation to look natural at any reasonable perspective value.
3. `box-shadow` on `.envelope` might interfere with `preserve-3d` despite not being spec-listed as a breaking property.

### Possible Next Steps

- **Isolated perspective context**: Wrap the flap in its own `env-flap-scene` div with `perspective: 600px` (no other transforms on this wrapper). This isolates the 3D context from the envelope's `translateX(-50%)`. The original invite-page branch used this approach.
- **Reduce flap height** to 40-45% so rotations don't create such large displaced shapes.
- **Hybrid approach**: Use the 2D scaleY shrink (which works) but make the "grow" phase more visually prominent - a larger env-flap-open with a scaleY grow animation, positioned above or at the top of the envelope rather than hidden behind the pocket-front.
- **Skip the flap animation entirely**: Jump-cut from sealed to open (crossfade the sealed state to the open state in ~300ms), then proceed to the letter rising. The letter emergence is the hero moment anyway.

## Current File State

Single file: `.worktrees/invite-page/website/invite/index.html`

Server: `python3 -m http.server 8080` from the invite directory.
Debug URL: `http://localhost:8080/index.html?debug&name=Mete`

### Key CSS Architecture

| Element | z-index | Purpose |
|---------|---------|---------|
| env-back | 1 | Envelope background |
| env-inner-shadow | 2 | Gradient shadow when open |
| env-flap-open | 2 | Inner surface (through V-notch) |
| letter-stage | 4 | Contains letter-card |
| env-pocket-front | 5 | Front surface with fold creases |
| env-name | 6 | Embossed name |
| env-flap | 7 | Triangular flap (front face) |
| wax-seal | 8 | Wax stamp image |

### Pocket-Front V-Notch

`clip-path: polygon(0 100%, 0 34%, 34% 34%, 50% 56%, 66% 34%, 100% 34%, 100% 100%)`

The horizontal edges at y=34% extend slightly beyond the flap triangle's coverage (about 5% on each side). This creates subtle horizontal line artifacts that are visible in the sealed state. Matching the pocket-front base gradient to env-back could minimize this.
