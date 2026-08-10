# Press-and-Hold Stamp Interaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Accept Invitation" click CTA with a press-and-hold circular button that triggers a stamp-slam animation, with a custom stamp cursor active throughout the letter interaction.

**Architecture:** Single-file changes to `website/invite/index.html`. The hold button uses a rAF loop for interactive progress tracking and spring-back physics. The stamp slam reuses the existing Web Animations API patterns. The stamp cursor is a base64-encoded PNG applied via CSS class toggling.

**Tech Stack:** HTML, CSS, JavaScript (vanilla), Web Animations API, SVG, requestAnimationFrame

**Spec:** `docs/superpowers/specs/2026-03-24-press-hold-stamp-design.md`

---

### Task 1: Prepare Stamp Cursor Asset

**Files:**
- Read: `assets/launch-assets/Remarc-Stamp.svg`
- Modify: `website/invite/index.html` (CSS section, around line 270)

This task converts the SVG stamp to a base64 PNG data URI and adds the cursor CSS rule.

- [ ] **Step 1: Convert SVG to PNG and base64-encode**

Use the `sips` and `base64` CLI tools (built into macOS) to convert the SVG. Since `sips` doesn't handle SVG, use a quick approach: create a tiny HTML file that renders the SVG to a canvas, then export as PNG. Alternatively, use `qlmanage` or `rsvg-convert` if available. The simplest reliable approach for macOS:

```bash
# Check if rsvg-convert is available
which rsvg-convert || brew list librsvg 2>/dev/null

# If not available, use Python with cairosvg or Pillow, or use a node script
# Fallback: manually create a base64 PNG cursor using a canvas-based approach
```

If tooling is limited, create a small Node.js or Python script to do the conversion:

```bash
# Using Node.js with sharp (if available)
node -e "
const sharp = require('sharp');
const fs = require('fs');
sharp('assets/launch-assets/Remarc-Stamp.svg')
  .resize(40, 46)
  .png()
  .toBuffer()
  .then(buf => console.log(buf.toString('base64')));
"
```

If no image processing tools are available, convert the SVG to a data URI cursor directly (most modern browsers support SVG cursors despite inconsistencies - test and fall back to PNG if needed):

```bash
# Encode SVG directly as base64
base64 -i assets/launch-assets/Remarc-Stamp.svg | tr -d '\n'
```

- [ ] **Step 2: Add stamp cursor CSS rule**

In `website/invite/index.html`, after the `.cta-invite:focus-visible` rule (line 269), before the `/* ===== Stamp ===== */` comment (line 271), add:

```css
/* ===== Stamp cursor ===== */
.stamp-cursor, .stamp-cursor *{
  cursor:url(data:image/png;base64,<BASE64_STRING_HERE>) 20 40, pointer;
}
```

Replace `<BASE64_STRING_HERE>` with the actual base64 string from Step 1. The hotspot `20 40` centers the press point at the bottom of the stamp handle.

- [ ] **Step 3: Verify cursor works**

Open the invite page in the browser, manually add `stamp-cursor` class to `.letter-card` via DevTools, confirm the cursor changes. Remove the class and confirm it reverts.

- [ ] **Step 4: Commit**

```bash
git add website/invite/index.html
git commit -m "feat(invite): add stamp cursor CSS rule with base64 PNG asset"
```

---

### Task 2: Add Hold Button HTML and CSS

**Files:**
- Modify: `website/invite/index.html`
  - HTML: line 851 (replace CTA button)
  - CSS: lines 252-269 (replace CTA styles with hold button styles)

- [ ] **Step 1: Replace CTA button HTML with hold button**

Replace the existing button at line 851:
```html
<button class="cta-invite" id="cta-accept" type="button">Accept Invitation</button>
```

With the hold button:
```html
<div class="hold-btn-area" id="hold-btn-area">
  <div class="hold-btn" id="hold-btn" role="button" tabindex="0" aria-label="Press and hold to accept invitation">
    <svg class="hold-ring-svg" viewBox="0 0 120 120" aria-hidden="true">
      <circle class="hold-ring-bg" cx="60" cy="60" r="54"/>
      <circle class="hold-ring-progress" id="hold-ring-progress" cx="60" cy="60" r="54"/>
    </svg>
    <span class="hold-btn-label">Press &amp; hold<br>to accept</span>
  </div>
  <span class="hold-btn-hint">hold for 2.5s</span>
</div>
```

- [ ] **Step 2: Replace CTA CSS with hold button CSS**

Replace the `.cta-invite` CSS block (lines 252-269) with:

```css
/* ===== Hold button ===== */
.hold-btn-area{
  display:flex;flex-direction:column;align-items:center;gap:12px;
  margin-top:32px;position:relative;z-index:12;
}
.hold-btn{
  width:130px;height:130px;border-radius:50%;position:relative;
  background:#cdd2de;
  box-shadow:
    inset 2px 2px 6px rgba(0,0,0,0.18),
    inset -1px -1px 4px rgba(255,255,255,0.5),
    0 1px 2px rgba(255,255,255,0.4);
  transition:transform 0.16s ease;
  -webkit-tap-highlight-color:transparent;
  cursor:inherit;
  user-select:none;-webkit-user-select:none;
}
.hold-btn:hover{transform:scale(1.02)}
.hold-btn:focus-visible{outline:2px solid rgba(99,102,241,0.66);outline-offset:4px}
.hold-ring-svg{
  position:absolute;inset:0;width:100%;height:100%;
  transform:rotate(-90deg);
}
.hold-ring-bg{
  fill:none;stroke:#b8bcc8;stroke-width:3.5;
}
.hold-ring-progress{
  fill:none;stroke:#4338CA;stroke-width:3.5;stroke-linecap:round;
  stroke-dasharray:339.29;stroke-dashoffset:339.29;
  filter:drop-shadow(0 0 4px rgba(99,102,241,0.4));
}
.hold-btn-label{
  position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  text-align:center;
  font-family:'SF Mono','Fira Code','Cascadia Code','JetBrains Mono',monospace;
  font-size:10.5px;font-weight:500;letter-spacing:0.3px;line-height:1.45;
  color:#4a4e5a;text-transform:uppercase;
  text-shadow:0 1px 0 rgba(255,255,255,0.6);
  padding:20px;
}
.hold-btn-hint{
  font-family:'SF Mono','Fira Code','Cascadia Code','JetBrains Mono',monospace;
  font-size:11px;color:#7a7e8a;letter-spacing:0.3px;
  text-shadow:0 1px 0 rgba(255,255,255,0.4);
}
```

- [ ] **Step 3: Verify visual appearance**

Open the invite page, skip to the letter state (use `?debug` mode or `skipToMain()`), and verify:
- Hold button appears embossed on the paper
- Monospace text is centered and readable
- Ring background is visible but subtle
- Hover shows subtle scale(1.02) effect

- [ ] **Step 4: Commit**

```bash
git add website/invite/index.html
git commit -m "feat(invite): replace Accept CTA with embossed hold button"
```

---

### Task 3: Reposition Stamp Area for Centered Placement

**Files:**
- Modify: `website/invite/index.html`
  - CSS: lines 272-276 (`.stamp-area` styles)

The current `.stamp-area` is absolutely positioned with `inset:0 0 34% 38%` which places it off-center on the letter. It needs to appear centered at the same position as the hold button.

- [ ] **Step 1: Update stamp-area CSS positioning**

Replace the `.stamp-area` CSS (lines 272-276):

```css
.stamp-area{
  position:absolute;inset:0 0 34% 38%;
  display:flex;align-items:center;justify-content:center;
  opacity:0;pointer-events:none;z-index:14;
}
```

With positioning that centers in the `.letter-footer` container:

```css
.stamp-area{
  display:flex;align-items:center;justify-content:center;
  opacity:0;pointer-events:none;z-index:14;
  margin-top:32px;
}
```

Note: The stamp area was previously positioned absolutely relative to the letter card. Now it should flow in the same container as the hold button (`.letter-footer`), taking the same centered position. The hold button area will be hidden and the stamp area shown in its place.

- [ ] **Step 2: Verify stamp still renders correctly**

Use `?debug` mode, click through to accept, verify the stamp renders centered where the hold button was. The stamp SVG size (`min(188px,44vw)`) should work well at this position.

- [ ] **Step 3: Commit**

```bash
git add website/invite/index.html
git commit -m "feat(invite): reposition stamp area to center in letter footer"
```

---

### Task 4: Implement Hold Interaction JavaScript

**Files:**
- Modify: `website/invite/index.html`
  - JS constants section: ~line 1100
  - JS variable declarations: ~line 1125
  - JS click handler: lines 1166-1173 (remove)
  - JS new hold logic: add after variable declarations

This is the core interaction: rAF-driven progress, spring-back physics, and the `waitForHoldComplete()` promise.

- [ ] **Step 1: Add constants**

After `var STAMP_CIRCUMFERENCE = 590.62;` (line 1102), add:

```javascript
var HOLD_DURATION = 2500;
var HOLD_RING_CIRCUMFERENCE = 339.29; /* 2 * PI * 54 */
var SPRING_DECAY = 8;
var SNAP_THRESHOLD = 0.01;
var BUTTON_EXIT_MS = 220;
var PAUSE_MS = 150;
var STAMP_SLAM_MS = 800;
```

- [ ] **Step 2: Add variable declarations**

After the existing element declarations (~line 1130), add:

```javascript
var holdBtn = document.getElementById('hold-btn');
var holdBtnArea = document.getElementById('hold-btn-area');
var holdRingProgress = document.getElementById('hold-ring-progress');
var holdProgress = 0;
var holdStartTime = 0;
var holdAnimFrame = null;
var isHolding = false;
var holdCompleteResolve = null;
```

- [ ] **Step 3: Remove old CTA click handler and update waitForClick filter**

Remove the `ctaAccept.addEventListener('click', ...)` block (lines 1166-1173). Also remove `var acceptResolve = null;` from line 1105.

Update the `waitForClick()` function (lines 1221-1235): change the click filter from `event.target.closest('#cta-accept')` to `event.target.closest('#hold-btn-area')`. This prevents debug-mode "click to continue" from firing when the user interacts with the hold button.

- [ ] **Step 4: Add hold interaction functions**

Add the following after the variable declarations:

```javascript
function waitForHoldComplete(){
  return new Promise(function(resolve){
    holdCompleteResolve = resolve;
  });
}

function updateHoldRing(progress){
  var offset = HOLD_RING_CIRCUMFERENCE * (1 - progress);
  holdRingProgress.style.strokeDashoffset = offset;
}

function holdAnimationLoop(timestamp){
  if(isHolding){
    // Filling phase
    var elapsed = timestamp - holdStartTime;
    holdProgress = Math.min(1, elapsed / HOLD_DURATION);
    updateHoldRing(holdProgress);

    if(holdProgress >= 1){
      // Hold complete
      isHolding = false;
      holdAnimFrame = null;
      if(holdCompleteResolve){
        var resolve = holdCompleteResolve;
        holdCompleteResolve = null;
        resolve();
      }
      return;
    }
  } else {
    // Spring-back decay phase
    holdProgress *= Math.exp(-SPRING_DECAY * (1/60));
    if(holdProgress < SNAP_THRESHOLD){
      holdProgress = 0;
      updateHoldRing(0);
      holdAnimFrame = null;
      return;
    }
    updateHoldRing(holdProgress);
  }
  holdAnimFrame = requestAnimationFrame(holdAnimationLoop);
}

function startHold(){
  isHolding = true;
  // Calculate start time accounting for existing progress
  var now = performance.now();
  holdStartTime = now - (holdProgress * HOLD_DURATION);
  if(!holdAnimFrame){
    holdAnimFrame = requestAnimationFrame(holdAnimationLoop);
  }
}

function stopHold(){
  if(!isHolding) return;
  isHolding = false;
  // rAF loop continues in decay mode
  if(!holdAnimFrame){
    holdAnimFrame = requestAnimationFrame(holdAnimationLoop);
  }
}
```

- [ ] **Step 5: Add event listeners for hold button**

Add after the hold functions:

```javascript
holdBtn.addEventListener('pointerdown', function(e){
  e.preventDefault();
  holdBtn.setPointerCapture(e.pointerId);
  startHold();
});
holdBtn.addEventListener('pointerup', function(e){
  stopHold();
});
holdBtn.addEventListener('pointercancel', function(e){
  stopHold();
});
// Prevent context menu on long press
holdBtn.addEventListener('contextmenu', function(e){
  e.preventDefault();
});
```

- [ ] **Step 6: Verify hold interaction**

Open invite page in `?debug` mode, navigate to the letter state:
- Press and hold the button - ring should fill over 2.5s
- Release early - ring should spring back to zero with decaying motion
- Press again during decay - should resume from current progress
- Hold to completion - ring fills fully

- [ ] **Step 7: Commit**

```bash
git add website/invite/index.html
git commit -m "feat(invite): implement press-and-hold interaction with spring-back physics"
```

---

### Task 5: Wire Hold Completion into Ceremony Flow

**Files:**
- Modify: `website/invite/index.html`
  - JS ceremony flow: lines 1439-1465

- [ ] **Step 1: Update the ceremony flow**

Replace lines 1439-1465 (from `ctaAccept.focus(...)` through the CTA fade-out animation) with:

```javascript
      holdBtn.focus({ preventScroll: true });

      // Add stamp cursor to letter card
      letterCard.classList.add('stamp-cursor');

      await waitForClick('Press and hold to accept');
      await waitForHoldComplete();

      // === Stamp ===
      localStorage.setItem('remarc-invite-accepted', Date.now().toString());
      document.body.dataset.state = 'accepted';

      // Fade out hold button (stamp cursor stays active through slam)
      await runAndCommit(holdBtnArea.animate([
        { opacity: 1, transform: 'scale(1)' },
        { opacity: 0, transform: 'scale(0.92)' }
      ], {
        duration: BUTTON_EXIT_MS,
        easing: 'ease-out',
        fill: 'forwards'
      }));

      holdBtnArea.hidden = true;
      stampArea.classList.add('visible');
      stampArea.setAttribute('aria-hidden', 'false');

      // Anticipation pause
      await delay(PAUSE_MS);
```

- [ ] **Step 2: Update the stamp slam keyframes**

The existing stamp-ring animation (following the code above) needs the `translateY(-60px)` added for the "from above" effect. Replace the existing `stampRing.animate(...)` call:

```javascript
      // Stamp slams from above
      await runAndCommit(stampRing.animate([
        { transform: 'scale(1.5) rotate(-8deg) translateY(-60px)', opacity: 0 },
        { transform: 'scale(0.96) rotate(-4deg) translateY(0)', opacity: 1, offset: 0.5 },
        { transform: 'scale(1.02) rotate(-3.5deg) translateY(0)', opacity: 1, offset: 0.75 },
        { transform: 'scale(1) rotate(-3deg) translateY(0)', opacity: 1, offset: 1 }
      ], {
        duration: STAMP_SLAM_MS,
        easing: 'cubic-bezier(0.22,1,0.36,1)',
        fill: 'forwards'
      }));

      // Stamp has landed - now revert cursor
      letterCard.classList.remove('stamp-cursor');
```

The rest of the ceremony flow (stamp progress ring animation, transition to main) remains unchanged.

- [ ] **Step 3: Remove all old ctaAccept references**

Find and remove `var ctaAccept = document.getElementById('cta-accept');` from the variable declarations (~line 1125).

Critically, the `resetCeremony()` function (around lines 1308-1310) has:
```javascript
ctaAccept.hidden = false;
ctaAccept.disabled = false;
ctaAccept.removeAttribute('style');
```
Remove these lines - the CTA element no longer exists. (Task 6 Step 1 adds the hold button reset code to replace this.)

Search for any other remaining `ctaAccept` references and remove or replace them.

- [ ] **Step 4: Test the full ceremony flow**

Open the invite page fresh (clear localStorage: `localStorage.removeItem('remarc-invite-accepted')`):
1. Envelope appears and opens
2. Letter rises - stamp cursor activates
3. Hold button visible at bottom of letter
4. Press and hold for 2.5s - ring fills
5. Button fades, stamp slams down from above
6. Cursor reverts to normal
7. Stamp progress ring animates
8. Transition to main page works

- [ ] **Step 5: Commit**

```bash
git add website/invite/index.html
git commit -m "feat(invite): wire hold completion into ceremony flow with stamp slam from above"
```

---

### Task 6: Polish and Edge Cases

**Files:**
- Modify: `website/invite/index.html`

- [ ] **Step 1: Handle the replay flow**

The page has a "Replay" button that resets the ceremony. Ensure the hold button resets properly on replay. Find the replay handler and add:

```javascript
// Reset hold state
holdProgress = 0;
updateHoldRing(0);
isHolding = false;
if(holdAnimFrame){ cancelAnimationFrame(holdAnimFrame); holdAnimFrame = null; }
holdBtnArea.hidden = false;
holdBtnArea.style.opacity = '';
holdBtnArea.style.transform = '';
```

- [ ] **Step 2: Handle skipToMain for returning users**

The `skipToMain()` function is called when the user has already accepted. Verify it still works correctly - it should bypass the hold button entirely since it jumps past the letter state.

- [ ] **Step 3: Test edge cases**

- Replay button resets hold state correctly
- Returning user (localStorage set) skips to main
- `?debug` mode works with new hold flow
- Rapid press/release cycles don't cause visual glitches
- Browser resize during hold doesn't break layout

- [ ] **Step 4: Commit**

```bash
git add website/invite/index.html
git commit -m "fix(invite): handle replay reset and edge cases for hold interaction"
```

---

### Task 7: Final Verification

- [ ] **Step 1: Full end-to-end test**

Clear all state and run the complete flow:
```javascript
localStorage.removeItem('remarc-invite-accepted');
location.reload();
```

Verify the complete ceremony:
1. Envelope fades in
2. Wax seal breaks, flap opens
3. Letter rises - **stamp cursor appears**
4. Hold button is embossed on paper, monospace text
5. Press and hold - ring fills with indigo glow
6. Release early - spring-back decay
7. Hold to completion - button fades, **stamp slams from above**
8. **Cursor reverts to normal**
9. Stamp progress ring draws
10. Transition to main page
11. Replay works correctly

- [ ] **Step 2: Cross-browser check**

Test in Safari and Chrome at minimum. Verify:
- Custom cursor renders (fallback to pointer if not)
- Hold interaction works in both browsers
- Stamp animations play correctly
- Safari filter fallbacks still work (`.is-safari` class)

- [ ] **Step 3: Final commit**

```bash
git add website/invite/index.html
git commit -m "feat(invite): press-and-hold stamp interaction complete"
```