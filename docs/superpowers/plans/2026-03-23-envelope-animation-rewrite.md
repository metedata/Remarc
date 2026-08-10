# Envelope Animation Rewrite - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the envelope animation on the early tester invite page to create a physically realistic 3D envelope opening where the flap opens with true perspective depth and the letter emerges from inside the envelope.

**Architecture:** Dual-context approach. The top flap lives in an isolated CSS 3D rendering context (`perspective` + `preserve-3d`), while the envelope body, letter, and shadows live in a standard 2D context. This avoids CSS properties (`filter`, `overflow`, `clip-path`) from flattening the 3D transforms. The letter sits in a tall clip container (`overflow: hidden`) behind the opaque envelope body (`z-index` layering). As the letter slides up, the body naturally hides the portion still "inside," while the portion above the body's top edge is visible - creating a physical emergence effect with no 3D conflicts.

**Note:** The original design spec says "No 3D transforms: 2D fold for flap to avoid Safari bugs." This plan intentionally upgrades to CSS 3D transforms because: (a) the user explicitly requested full physical realism, (b) Safari 17.4+ (macOS 14.4+ target) handles `perspective` + `preserve-3d` reliably, and (c) the dual-context approach isolates 3D to the flap only, avoiding the known gotchas. This plan supersedes the spec on that point.

**Tech Stack:** Vanilla HTML/CSS/JS, Web Animations API, CSS 3D Transforms

**Key CSS 3D Rules (from research):**
- `filter`, `overflow: hidden`, `clip-path`, `opacity < 1`, `mix-blend-mode` on a parent **all force `transform-style: flat`**, destroying 3D on children
- Workaround: push those properties to leaf elements or separate DOM branches
- `perspective` goes on the scene container, `transform-style: preserve-3d` on the rotating element
- `backface-visibility: hidden` on each face to hide the reverse when rotated

---

## File Map

All changes are in a single file:
- **Modify:** `.worktrees/invite-page/website/invite/index.html`
  - CSS section: Rewrite envelope styles (delete `.envelope` through `.env-name` rules, replace `.letter-card` rule), remove old side-flap and env-flap rules
  - HTML section: Restructure envelope DOM (the `#envelope` block) to dual-context
  - JS section: Update `runCeremony()` function and replay handler for new element IDs

---

## Task 1: Restructure Envelope HTML to Dual-Context DOM

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (HTML, lines 407-475)

- [ ] **Step 1: Replace envelope HTML block**

Replace everything from `<!-- Envelope (contains letter inside) -->` (line 410) through the closing `</div>` of `.envelope` (line 473) with the new dual-context structure:

```html
<!-- Envelope shadow wrapper (drop-shadows here, OUTSIDE any 3D context) -->
<div class="envelope-shadow" id="envelope-shadow">
  <div class="envelope" id="envelope">
    <!-- Back body (opaque rectangle, z:2 - covers letter behind it) -->
    <div class="env-body" id="env-body">
      <div class="paper-noise"></div>
      <div class="env-fold-lines"></div>
    </div>

    <!-- Inner depth shadow (z:3, opacity:0 initially, fades in when flap opens) -->
    <div class="env-inner-shadow" id="env-inner-shadow"></div>

    <!-- Letter clip container (z:1, behind body - overflow:hidden clips bottom) -->
    <div class="letter-clipper" id="letter-clipper">
      <div class="letter-card" id="letter-card">
        <div class="paper-noise"></div>
        <div class="letter-salutation">Dear <span id="letter-name"></span>,</div>
        <div class="letter-body">
          <p>You've been invited to join a small group getting early access to Remarc.</p>
          <p>I built this for people like us - builders who care about the details, who won't ship until it feels right. Remarc is your feedback layer for working with AI. I think you'll get it.</p>
          <p>Your voice will shape what this becomes. I'm grateful you're here.</p>
        </div>
        <div class="letter-signature">- Mete</div>
        <div class="letter-footer" id="letter-footer">
          <button class="cta-invite" id="cta-accept">Accept Invitation</button>
          <div class="stamp-area" id="stamp-area">
            <div class="stamp-ring">
              <svg class="stamp-svg" viewBox="0 0 200 200" id="stamp-svg">
                <defs>
                  <path id="arc-top" d="M 18,100 a 82,82 0 1,1 164,0" fill="none"/>
                  <path id="arc-bottom" d="M 182,100 a 82,82 0 1,1 -164,0" fill="none"/>
                </defs>
                <circle cx="100" cy="100" r="96" fill="none" stroke="rgba(99,102,241,0.06)" stroke-width="1"/>
                <circle id="stamp-progress" cx="100" cy="100" r="96"
                  fill="none" stroke="rgba(99,102,241,0.35)" stroke-width="1.5"
                  stroke-dasharray="603.19" stroke-dashoffset="603.19"
                  stroke-linecap="round" transform="rotate(-90 100 100)"/>
                <circle cx="100" cy="100" r="90" fill="none" stroke="var(--indigo)" stroke-width="2" opacity="0.5"/>
                <circle cx="100" cy="100" r="72" fill="none" stroke="var(--indigo)" stroke-width="1" opacity="0.25"/>
                <circle cx="100" cy="8" r="1.5" fill="var(--indigo)" opacity="0.35"/>
                <circle cx="100" cy="192" r="1.5" fill="var(--indigo)" opacity="0.35"/>
                <circle cx="8" cy="100" r="1.5" fill="var(--indigo)" opacity="0.35"/>
                <circle cx="192" cy="100" r="1.5" fill="var(--indigo)" opacity="0.35"/>
                <text font-family="system-ui,sans-serif" font-size="10.5" fill="var(--indigo)" letter-spacing="4.5" font-weight="600" opacity="0.55">
                  <textPath href="#arc-top" startOffset="50%" text-anchor="middle">INVITATION ACCEPTED</textPath>
                </text>
                <text font-family="system-ui,sans-serif" font-size="9.5" fill="var(--indigo)" letter-spacing="3.5" font-weight="500" opacity="0.4">
                  <textPath href="#arc-bottom" startOffset="50%" text-anchor="middle" id="stamp-name-text"></textPath>
                </text>
                <g transform="translate(78,74) scale(1.9)" opacity="0.45">
                  <path fill-rule="evenodd" clip-rule="evenodd"
                    d="M12.25 0C16.8063 0 20.5 3.69365 20.5 8.25C20.5 11.6201 18.4779 14.5153 15.582 15.7959C17.8381 19.4441 20.1656 21.2935 22.625 22.6592C22.9018 22.8129 22.7941 23.2494 22.4775 23.248C16.3305 23.2219 16.2304 23.6772 11.4364 16.9269C11.2486 16.6624 10.941 16.5 10.6165 16.5H7.82064C7.57395 16.5 7.33598 16.5912 7.15245 16.756L0 23.1797V4.75C0 2.12665 2.12665 0 4.75 0H12.25ZM4.75 3.5C4.05964 3.5 3.5 4.05964 3.5 4.75V15.3203L5.00879 13.9629C5.69738 13.3432 6.59117 13 7.51758 13H12.25C14.8734 13 17 10.8733 17 8.25C17 5.62665 14.8734 3.5 12.25 3.5H4.75Z"
                    fill="var(--indigo)"/>
                </g>
              </svg>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- 3D Flap scene (isolated perspective context) -->
    <div class="env-flap-scene" id="env-flap-scene">
      <div class="env-flap" id="env-flap">
        <div class="env-flap-outside"></div>
        <div class="env-flap-inside"></div>
      </div>
    </div>

    <!-- Wax seal (z:7, on top of everything) -->
    <img class="wax-seal" id="wax-seal" src="remarc-wax-stamp.png" alt="Wax seal" width="112" height="112">
    <!-- Embossed name (z:4, on envelope front) -->
    <div class="env-name" id="env-name"></div>
  </div>
</div>
```

**Key structural changes:**
- Added `.envelope-shadow` wrapper for `filter: drop-shadow()` (outside 3D context)
- Added `.letter-clipper` with `overflow: hidden` at `z-index: 1` (behind body at z:2) - extends 250% upward so letter can emerge above body without being clipped at top
- Replaced single `.env-flap` with `.env-flap-scene` (perspective container) > `.env-flap` (preserve-3d) > two face divs
- Removed `.env-side-left` and `.env-side-right` elements (replaced by fold-line gradients on body)
- Added `.env-inner-shadow` element for depth illusion when flap opens
- **Removed all inline `style="position:relative;z-index:3"` attributes** from letter-card children. The old code had these to work around the broken z-index stacking. The new structure handles stacking via the clipper's z-index, so inline styles are unnecessary and would conflict with `position: absolute` on `.letter-card`.
- **Stamp SVG is inlined** in the template above (no need to copy from old file)

- [ ] **Step 2: Verify page loads without JS errors**

Open `.worktrees/invite-page/website/invite/index.html?name=Joe&debug` in browser. Check console for errors. Layout will be broken (CSS changes come next).

- [ ] **Step 3: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "refactor: restructure envelope HTML to dual-context architecture"
```

---

## Task 2: Style Envelope Body, Shadows, and Fold Details

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (CSS, lines 176-269)

- [ ] **Step 1: Delete old envelope CSS rules**

Remove these CSS rule blocks entirely:
- `.envelope` (lines 177-190)
- `.env-body` (lines 193-201)
- `.env-side-left, .env-side-right` (lines 204-209)
- `.env-side-left::before, .env-side-right::before` (lines 210-214)
- `.env-side-left::before` (lines 216-219)
- `.env-side-right::before` (lines 221-224)
- `.env-flap` (lines 227-234)
- `.env-flap::before` (lines 236-244)
- `.wax-seal` (lines 247-253)
- `.env-name` (lines 256-269)

- [ ] **Step 2: Add new envelope CSS rules**

Insert the following CSS in place of the deleted rules:

```css
/* --- Shadow wrapper (filter lives here, outside 3D context) --- */
.envelope-shadow{
  filter:
    drop-shadow(0 1px 2px rgba(0,0,0,0.10))
    drop-shadow(0 6px 16px rgba(0,0,0,0.14))
    drop-shadow(0 20px 48px rgba(0,0,0,0.20));
}

/* --- Envelope container --- */
.envelope{
  width:var(--env-w);
  height:calc(var(--env-w) * 0.55);
  position:relative;
  z-index:3;
  margin-top:-2px;
}

/* --- Body (opaque rectangle, covers letter behind it) --- */
.env-body{
  position:absolute;inset:0;
  background:linear-gradient(180deg,#c0c6d0 0%,var(--paper-body) 30%,#b0b6c2 100%);
  border-radius:3px;
  z-index:2;
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.2),
    inset 0 -1px 0 rgba(0,0,0,0.04);
  overflow:hidden; /* safe - not a 3D parent */
}

/* Diagonal fold lines (where side flaps fold inside a real envelope) */
.env-fold-lines{
  position:absolute;inset:0;pointer-events:none;z-index:1;
}
.env-fold-lines::before,
.env-fold-lines::after{
  content:'';position:absolute;top:0;bottom:0;width:50%;
}
.env-fold-lines::before{
  left:0;
  background:linear-gradient(to bottom right,rgba(0,0,0,0.035) 0%,transparent 48%,transparent 100%);
}
.env-fold-lines::after{
  right:0;
  background:linear-gradient(to bottom left,rgba(0,0,0,0.035) 0%,transparent 48%,transparent 100%);
}

/* Inner depth shadow (appears when flap opens) */
.env-inner-shadow{
  position:absolute;
  top:0;left:0;right:0;
  height:35%;
  background:linear-gradient(180deg,rgba(0,0,0,0.12) 0%,rgba(0,0,0,0.04) 40%,transparent 100%);
  border-radius:3px 3px 0 0;
  z-index:3;
  opacity:0;
  pointer-events:none;
}
```

- [ ] **Step 3: Verify envelope body renders**

Open in browser. Should see a slate-colored rectangle with faint diagonal fold shadows. No side flap triangles. Inner shadow invisible.

- [ ] **Step 4: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "style: envelope body with shadow wrapper and fold details"
```

---

## Task 3: Build the 3D Flap with Front and Back Faces

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (CSS)

- [ ] **Step 1: Add 3D flap scene styles**

Add after the envelope body rules:

```css
/* --- 3D Flap (isolated perspective context) --- */
.env-flap-scene{
  position:absolute;
  top:0;left:0;right:0;
  height:55%;
  z-index:5;
  perspective:800px;
  pointer-events:none; /* pass clicks through to letter/CTA below */
  /* CRITICAL: no filter, overflow, opacity<1, mix-blend-mode here */
}

.env-flap{
  position:absolute;
  width:100%;height:100%;
  transform-origin:top center;
  transform-style:preserve-3d;
}

/* Front face (visible when closed) */
.env-flap-outside{
  position:absolute;
  width:100%;height:100%;
  background:linear-gradient(180deg,#c8ced8 0%,#bcc2ce 60%,#b5bbc6 100%);
  clip-path:polygon(0 0,100% 0,50% 100%);
  backface-visibility:hidden;
  -webkit-backface-visibility:hidden;
}

/* Inner face (visible when flap rotates past 90deg) */
.env-flap-inside{
  position:absolute;
  width:100%;height:100%;
  background:linear-gradient(0deg,#a8aebb 0%,#b0b6c3 50%,#bbc1cd 100%);
  clip-path:polygon(0 0,100% 0,50% 100%);
  backface-visibility:hidden;
  -webkit-backface-visibility:hidden;
  transform:rotateX(180deg);
}
```

**Why `clip-path` is safe here:** `clip-path` on `.env-flap-outside` and `.env-flap-inside` does NOT break 3D because these are **leaf elements** (no 3D children). The `clip-path` restriction only matters on elements that have `transform-style: preserve-3d` children. The leaf faces just need to be shaped - they don't preserve 3D for anything below them.

- [ ] **Step 2: Verify flap renders as a triangle**

Open in browser. A downward-pointing triangle should appear at the top of the envelope body, slightly lighter shade. Only the front face should be visible.

- [ ] **Step 3: Test 3D rotation in DevTools**

In browser DevTools, find `.env-flap` and add `transform: rotateX(120deg)`. The front face should disappear and the inner face (darker shade) should be visible, with perspective foreshortening. This confirms the 3D dual-face setup works.

- [ ] **Step 4: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "feat: 3D envelope flap with dual-face backface-visibility"
```

---

## Task 4: Letter Clip Container and Positioning

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (CSS)

- [ ] **Step 1: Add letter clipper styles**

```css
/* --- Letter clip container --- */
/* z:1 = behind env-body (z:2), so body hides letter within its bounds.
   height:250% extends far above envelope so letter isn't clipped at top.
   overflow:hidden clips letter at bottom (prevents peeking below envelope). */
.letter-clipper{
  position:absolute;
  bottom:0;left:0;right:0;
  height:250%;
  z-index:1;
  overflow:hidden;
  pointer-events:none;
}
```

- [ ] **Step 2: Replace letter-card styles**

Delete the existing `.letter-card` rule (early in the CSS, around lines 76-100 - the one with `position:absolute` then `position:relative`). Replace with:

```css
.letter-card{
  position:absolute;
  bottom:5%;
  left:50%;
  transform:translateX(-50%);
  width:var(--letter-w);
  background:var(--paper-letter);
  padding:clamp(32px,5vw,48px) clamp(28px,4.5vw,44px);
  padding-bottom:clamp(36px,5vw,56px);
  border-radius:2px;
  color:#2a2e3d;
  box-shadow:
    0 1px 1px rgba(0,0,0,0.06),
    0 2px 4px rgba(0,0,0,0.06),
    0 4px 8px rgba(0,0,0,0.08),
    0 8px 24px rgba(0,0,0,0.12),
    0 20px 48px rgba(0,0,0,0.15),
    inset 0 1px 0 rgba(255,255,255,0.5),
    inset 0 -1px 0 rgba(0,0,0,0.03);
  min-height:480px;
  display:flex;flex-direction:column;
  opacity:0; /* JS sets to 1 when letter emerges */
  pointer-events:auto;
}
```

- [ ] **Step 3: Verify letter is hidden behind envelope**

Open in browser. Letter should NOT be visible (behind opaque body at z:2). In DevTools, temporarily set `.letter-card { opacity: 1 }` - you should NOT see the letter (it's behind the body). Then set `.letter-clipper { z-index: 10 }` - the letter should appear, confirming it exists and is properly sized.

- [ ] **Step 4: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "style: letter clip container for inside-envelope positioning"
```

---

## Task 5: Wax Seal and Embossed Name Positioning

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (CSS)

- [ ] **Step 1: Add wax seal and name styles**

```css
/* --- Wax seal (at center of closed flap's triangle) --- */
.wax-seal{
  position:absolute;
  /* Flap is 55% of envelope height; triangle center is ~1/3 down from top */
  top:calc(55% * 0.33);
  left:50%;
  transform:translate(-50%,-50%);
  width:112px;height:112px;
  z-index:7;
}

/* --- Embossed name on envelope front --- */
.env-name{
  position:absolute;
  bottom:12%;left:0;right:0;
  text-align:center;
  font-family:Georgia,'Times New Roman',serif;
  font-size:clamp(16px,3vw,22px);
  letter-spacing:6px;
  font-style:italic;
  color:rgba(140,148,168,0.65);
  text-shadow:
    0px -1px 0px rgba(70,75,95,0.3),
    0px 1px 0px rgba(255,255,255,0.45);
  z-index:4;
}
```

- [ ] **Step 2: Verify seal and name positions**

Seal should sit near the center of the triangular flap. Name should be in the lower portion of the envelope body. Adjust `top: calc(55% * 0.33)` if seal doesn't align well with the flap's visual center.

- [ ] **Step 3: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "style: wax seal and embossed name positioning"
```

---

## Task 6: Update JavaScript Animation Ceremony

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (JS `<script>` block)

This is the largest task - updating all animation code to work with the new DOM structure. Line numbers below are approximate and refer to the pre-edit file; use function names and element IDs to locate code.

- [ ] **Step 1: Add new DOM references**

After the existing DOM variable declarations (search for `var replayLink`), add:

```javascript
var envInnerShadow = document.getElementById('env-inner-shadow');
var letterClipper = document.getElementById('letter-clipper');
```

- [ ] **Step 2: Update the runCeremony function**

Replace the entire `runCeremony` function body with the updated version. Key changes:
- Seal break: updated transforms for new `top` position
- Flap open: targets `envFlap` (now inside isolated 3D scene), rotates to 165deg (not 180 - inner face stays slightly visible)
- Inner shadow: fades in simultaneously with flap open
- Letter emergence: calculates emerge distance from letter's position inside the clipper to above the envelope body

```javascript
async function runCeremony(){
  sceneEnv.classList.add('active');
  document.body.style.overflow = 'hidden';

  // Letter starts hidden
  letterCard.style.opacity = '0';
  layout.style.opacity = '0';
  layout.style.transform = 'scale(0.96)';

  await delay(300);

  // === STATE 1: Envelope fades in ===
  var a1 = layout.animate([
    {opacity:0,transform:'scale(0.96)'},
    {opacity:1,transform:'scale(1)'}
  ],{duration:900,easing:'cubic-bezier(0.16,1,0.3,1)',fill:'forwards'});
  await a1.finished; a1.commitStyles(); a1.cancel();

  await waitForClick('Click to open envelope');
  if(!DEBUG) await delay(2000);

  // === STATE 2: Seal breaks, then flap opens ===
  var a3 = waxSeal.animate([
    {transform:'translate(-50%,-50%) scale(1)',opacity:1,offset:0},
    {transform:'translate(-50%,-50%) scale(1.08) translateY(-8px)',opacity:1,offset:0.25},
    {transform:'translate(-50%,-50%) scale(0.9) translateY(40px)',opacity:0,offset:1}
  ],{duration:600,easing:'cubic-bezier(0.4,0,1,1)',fill:'forwards'});

  await delay(300);

  // Flap opens with real 3D rotation (hinged at top, inside isolated perspective context)
  var a2 = envFlap.animate([
    {transform:'rotateX(0deg)'},
    {transform:'rotateX(165deg)'}
  ],{duration:900,easing:'cubic-bezier(0.22,1,0.36,1)',fill:'forwards'});

  // Inner depth shadow fades in as flap opens
  var aInner = envInnerShadow.animate([
    {opacity:0},
    {opacity:1}
  ],{duration:500,easing:'ease-out',fill:'forwards',delay:200});

  await a3.finished; a3.commitStyles(); a3.cancel();
  await a2.finished; a2.commitStyles(); a2.cancel();
  await aInner.finished; aInner.commitStyles(); aInner.cancel();

  await waitForClick('Click to pull letter out');
  if(!DEBUG) await delay(400);

  // === STATE 3: Letter emerges from inside envelope ===
  // Do NOT set letterCard.style.opacity = '1' directly - that would flash
  // the letter for one frame before the animation starts. Instead, animate
  // opacity as part of the keyframes (0 -> 1 in first 3% of duration).

  // Calculate emerge distance:
  // Clipper is 250% of envelope height, anchored at bottom:0.
  // Clipper height = 2.5 * envH. Letter is at bottom:5% of clipper.
  // Letter bottom edge starts at 0.05 * 2.5 * envH = 0.125 * envH from clipper bottom.
  // Envelope body top is at envH from clipper bottom.
  // Distance from letter bottom to body top = envH - 0.125 * envH = 0.875 * envH.
  // To fully clear: add letterH (so entire letter is above body) + breathing room.
  var envH = envelope.offsetHeight;
  var clipperH = envH * 2.5;
  var letterH = letterCard.offsetHeight;
  var letterBottomFromClipperBottom = 0.05 * clipperH;
  var bodyTopFromClipperBottom = envH;
  var emergeDist = (bodyTopFromClipperBottom - letterBottomFromClipperBottom) + letterH + 32;

  var a4 = letterCard.animate([
    {transform:'translateX(-50%) translateY(0)',opacity:0,offset:0},
    {transform:'translateX(-50%) translateY(0)',opacity:1,offset:0.03},
    {transform:'translateX(-50%) translateY(-' + emergeDist + 'px)',opacity:1,offset:1}
  ],{duration:1200,easing:'cubic-bezier(0.16,1,0.3,1)',fill:'forwards'});

  await a4.finished; a4.commitStyles(); a4.cancel();

  await waitForClick('Click "Accept Invitation" to continue');

  // === STATE 4: Wait for CTA click ===
  await new Promise(function(resolve){
    ctaAccept.addEventListener('click',function handler(){
      ctaAccept.removeEventListener('click',handler);
      resolve();
    });
  });

  // === STATE 5: Stamp slams onto letter ===
  localStorage.setItem('remarc-invite-accepted',Date.now().toString());

  var a5 = ctaAccept.animate([
    {opacity:1,transform:'scale(1)'},
    {opacity:0,transform:'scale(0.9)'}
  ],{duration:200,easing:'ease-out',fill:'forwards'});
  await a5.finished; a5.commitStyles(); a5.cancel();
  ctaAccept.style.display = 'none';

  stampArea.classList.add('visible');
  var stampRing = stampArea.querySelector('.stamp-ring');

  var a6 = stampRing.animate([
    {transform:'rotate(-12deg) scale(2.5)',opacity:0},
    {transform:'rotate(-8deg) scale(0.92)',opacity:1,offset:0.4},
    {transform:'rotate(-8deg) scale(1.04)',offset:0.65},
    {transform:'rotate(-8deg) scale(0.99)',offset:0.8},
    {transform:'rotate(-8deg) scale(1)',opacity:1}
  ],{duration:600,easing:'cubic-bezier(0.22,1,0.36,1)',fill:'forwards'});
  await a6.finished; a6.commitStyles(); a6.cancel();

  var a7 = stampProgress.animate([
    {strokeDashoffset:603.19},
    {strokeDashoffset:0}
  ],{duration:3000,easing:'cubic-bezier(0.4,0,0.2,1)',fill:'forwards'});
  await a7.finished; a7.commitStyles(); a7.cancel();

  await waitForClick('Click to continue to early access');
  if(!DEBUG) await delay(600);

  // === STATE 6: Transition to main page ===
  var a8 = sceneEnv.animate([
    {opacity:1,transform:'translateY(0) scale(1)'},
    {opacity:0,transform:'translateY(-30px) scale(0.98)'}
  ],{duration:500,easing:'ease-in',fill:'forwards'});
  await a8.finished; a8.commitStyles(); a8.cancel();
  sceneEnv.classList.remove('active');

  sceneMain.classList.add('active');
  document.body.style.overflow = '';

  var mc = sceneMain.querySelector('.main-content');
  var children = mc.children;
  for(var i = 0; i < children.length; i++){
    (function(el, idx){
      el.style.opacity = '0';
      el.style.transform = 'translateY(24px)';
      setTimeout(function(){
        var a = el.animate([
          {opacity:0,transform:'translateY(24px)'},
          {opacity:1,transform:'translateY(0)'}
        ],{duration:600,easing:'cubic-bezier(0.16,1,0.3,1)',fill:'forwards'});
        a.finished.then(function(){ a.commitStyles(); a.cancel(); });
      }, idx * 100);
    })(children[i], i);
  }
}
```

- [ ] **Step 3: Update replay handler**

Update the `replayLink` event listener to reset new elements:

```javascript
replayLink.addEventListener('click',function(){
  localStorage.removeItem('remarc-invite-accepted');

  sceneMain.classList.remove('active');
  sceneEnv.classList.remove('active');

  // Strip all inline styles from animated elements (includes new ones)
  [sceneEnv, layout, letterCard, envelope,
   envFlap, waxSeal, ctaAccept, envInnerShadow].forEach(function(el){
    el.removeAttribute('style');
  });

  var mc = sceneMain.querySelector('.main-content');
  if(mc){
    mc.removeAttribute('style');
    for(var j=0;j<mc.children.length;j++) mc.children[j].removeAttribute('style');
  }

  stampArea.classList.remove('visible');
  stampProgress.setAttribute('stroke-dashoffset','603.19');
  stampProgress.removeAttribute('style');
  var sr = stampArea.querySelector('.stamp-ring');
  if(sr) sr.removeAttribute('style');

  requestAnimationFrame(function(){
    setTimeout(runCeremony, 50);
  });
});
```

- [ ] **Step 4: Verify full ceremony in debug mode**

Open `index.html?name=Joe&debug` and click through:
1. Envelope fades in with scale
2. Click - seal lifts then drops/fades
3. Flap rotates open with 3D perspective, inner face visible as it passes 90deg
4. Inner shadow gradient appears at envelope top
5. Click - letter slides up from inside envelope, emerging above the body
6. Click "Accept Invitation" - stamp slams, progress ring fills
7. Click - transitions to main page with stagger animation

- [ ] **Step 5: Verify auto-play mode**

Open `index.html?name=Joe` (no debug). Full ceremony plays with timed pauses.

- [ ] **Step 6: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "feat: update animation ceremony for 3D dual-context envelope"
```

---

## Task 7: Verify All User Flows

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html` (if fixes needed)

- [ ] **Step 1: Test returning visitor**

1. Complete ceremony, click Accept
2. Reload page
3. Should skip directly to main page (localStorage has `remarc-invite-accepted`)

- [ ] **Step 2: Test replay**

1. On main page, click "Replay invitation"
2. Full ceremony should replay from scratch
3. All elements should reset cleanly (no leftover styles)

- [ ] **Step 3: Test reduced motion**

1. Enable System Settings > Accessibility > Display > Reduce motion
2. Reload - should skip directly to main
3. Disable reduce motion after testing

- [ ] **Step 4: Test no-name fallback**

Open `index.html` (no `?name=` param). Should show "Dear Friend," and "Friend" on envelope.

- [ ] **Step 5: Test mobile gate**

Resize browser to <= 768px width, reload. Should show mobile gate with copy link button.

- [ ] **Step 6: Fix any issues, commit if changes made**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "fix: address edge cases in envelope flows"
```

---

## Task 8: Visual Polish

**Files:**
- Modify: `.worktrees/invite-page/website/invite/index.html`

- [ ] **Step 1: Tune flap proportions**

Watch the ceremony. If the flap triangle looks too tall or short relative to a real envelope, adjust `.env-flap-scene { height: 55% }`. Standard C5 envelope flap is roughly 40-50% of body height - 55% may need reducing.

- [ ] **Step 2: Tune shadow depth**

Adjust `.envelope-shadow` drop-shadow values if the envelope looks too flat or too detached from the background. Target: grounded, premium feel.

- [ ] **Step 3: Tune animation timing**

Watch the full ceremony 3-5 times. Check:
- Seal break feels physical (lift then drop)
- Flap opening speed feels weighted (paper has mass)
- Letter emergence is smooth and satisfying
- No jarring transitions between states

Adjust `duration` and `easing` values as needed.

- [ ] **Step 4: Verify wax seal aligns with flap center**

If the seal doesn't sit at the visual center of the closed triangle, adjust `.wax-seal { top: calc(55% * 0.33) }`. The 0.33 factor should put it at 1/3 down the flap height (which is the centroid of the triangle).

- [ ] **Step 5: Commit**

```bash
cd .worktrees/invite-page && git add website/invite/index.html && git commit -m "polish: fine-tune envelope proportions, shadows, and timing"
```
