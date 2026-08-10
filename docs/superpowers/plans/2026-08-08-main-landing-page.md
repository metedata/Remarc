# Main Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Coming Soon" page at `website/index.html` with the public Remarc landing page, adapted from the early-tester invite page per the approved spec (`docs/superpowers/specs/2026-08-08-main-landing-page-design.md`).

**Architecture:** Single self-contained HTML file (inline CSS/JS, no build step), seeded from `website/invite/index.html`, then edited task-by-task: strip the invitation ceremony, rewrite head/meta, port the Relinq icon tilt+shine, swap YouTube for a self-hosted video on R2, build a dual CTA row with an auto-hiding star chip, rewrite the FAQ, and add a footer. The invite page itself is never touched.

**Tech Stack:** Static HTML/CSS/JS. ffmpeg (poster extraction), wrangler (R2 upload), python3 http.server (local preview), the in-app browser for visual verification.

## Global Constraints

- All work happens in worktree `.worktrees/main-landing-page` on branch `feat/main-landing-page` (repo policy: never commit code changes on main).
- The ONLY repo file created/modified is `website/index.html`. `website/invite/` stays byte-identical. Video assets go to R2, not the repo.
- All CSS/JS stays inline in the single HTML file (matches invite-page convention).
- User-facing copy NEVER uses em dashes (—). Use hyphens (-). This includes FAQ answers, meta descriptions, captions, JSON-LD text.
- Subtitle text, exactly: `The feedback layer between you and your coding agent.`
- Download caption, exactly: `Requires macOS 14.0 or later`
- GitHub repo URL everywhere: `https://github.com/metedata/Remarc`
- Star chip: reveal threshold 25 stars, localStorage cache TTL 1 hour, key `gh-stars:metedata/Remarc`, compact format via `Intl.NumberFormat`, silent on failure.
- Icon: 96px desktop / 80px mobile, border-radius 19px / 16px. Tilt max 8deg, scale 1.02, disabled on touch via `(hover: none)`.
- Mobile breakpoint: `max-width:768px`.
- Kept sections (background stack, feedback section, FAQ accordion mechanics, dust canvas) are NOT restyled - copy them through unchanged.
- Line numbers below refer to `website/invite/index.html` at commit `6fcc909` (identical in the seeded copy before Task 2 edits). Prefer the quoted content anchors over line numbers once editing begins.

---

### Task 1: Worktree + seed the new page from the invite page

**Files:**
- Create: `.worktrees/main-landing-page/` (worktree, branch `feat/main-landing-page`)
- Create: `website/index.html` (overwrites the "Coming Soon" placeholder with a copy of the invite page)

**Interfaces:**
- Produces: worktree at `$REPO_ROOT/.worktrees/main-landing-page`; all later tasks run inside it and edit `website/index.html` there.

- [ ] **Step 1: Create the worktree**

```bash
cd $REPO_ROOT
git worktree add .worktrees/main-landing-page -b feat/main-landing-page
```

Expected: `Preparing worktree (new branch 'feat/main-landing-page')`.

- [ ] **Step 2: Seed the page**

```bash
cd $REPO_ROOT/.worktrees/main-landing-page
cp website/invite/index.html website/index.html
wc -l website/index.html
```

Expected: `1818 website/index.html`.

- [ ] **Step 3: Commit the seed**

```bash
git add website/index.html
git commit -m "chore: seed main landing page from invite page"
```

Rationale: committing the verbatim copy first makes every later diff reviewable as "what changed vs the invite page".

---

### Task 2: Strip the ceremony - land straight in the final state

**Files:**
- Modify: `website/index.html` (large deletions; file should shrink from ~1818 to roughly 550-650 lines)

**Interfaces:**
- Consumes: seeded file from Task 1.
- Produces: a static page where `#scene-main` (class `scene active`) is the only scene; `.stagger-item` entrance is pure CSS (`rise-in` keyframes); kept scripts are only the FAQ accordion script and the dust-particle script. Later tasks rely on: `.main-content` children order, `.stagger-item` class, `[hidden]{display:none !important}` rule, `--indigo`/`--indigo-hover`/`--indigo-active` CSS vars.

All edits below are in `website/index.html`. Use unique content anchors with the Edit tool.

- [ ] **Step 1: Slim the `:root` variables**

Replace the whole `:root{...}` block (invite lines 17-33, starts `--bg:#0a0a0c;`, ends `--letter-w:calc(var(--env-w) * 0.82);`) with:

```css
:root{
  --bg:#0a0a0c;
  --indigo:#6366F1;
  --indigo-hover:#818cf8;
  --indigo-active:#4f46e5;
}
```

- [ ] **Step 2: Delete ceremony CSS blocks**

Delete each of these blocks entirely (first line → last line):

1. `/* ===== SVG paper grain overlay ===== */` through the `.letter-card > .paper-noise{...}` block (lines 125-139).
2. The line `#scene-envelope{z-index:10}` (line 152).
3. `/* ===== Envelope staging ===== */` (line 154) through the `body[data-state="opening"] .env-inner-shadow, ... { opacity:1; }` block ending at line 502 - everything between the `.scene.active{...}` rule and the `/* ===== MAIN PAGE ===== */` comment, except keep the `/* ===== MAIN PAGE ===== */` comment itself.
4. `.play-icon{`, `.play-icon::after{`, `.video-placeholder-text{` rules (lines 538-548, dead video-placeholder styles).
5. `.replay-link{` (line 622) through `.replay-link:hover span{max-width:120px;opacity:1}` (line 644), including the `body[data-state="main"] .replay-link{...}` rule.
6. `/* ===== REVEAL SCENE (R icon animation) ===== */` (line 646) through `@keyframes rv-light-sweep{...}` (line 715).
7. `/* ===== MOBILE GATE ===== */` (line 717) through `.mobile-copy-btn:hover{...}` (line 743).
8. `/* ===== Debug ===== */` (line 745) through `body.debug-mode .debug-hint{display:block}` (line 752).
9. The three ceremony media queries (lines 755-765): `@media (max-height:860px){...}`, `@media (max-width:640px){...}`, `@media (max-width:480px){...}`. Keep the `@media (prefers-reduced-motion:reduce)` block.

- [ ] **Step 3: Replace the `.stagger-item` default with a CSS entrance**

Replace:

```css
.stagger-item{
  opacity:0;transform:translateY(28px);
  will-change:transform,opacity;
}
```

with:

```css
.stagger-item{
  opacity:0;transform:translateY(28px);
  will-change:transform,opacity;
  animation:rise-in 0.7s cubic-bezier(0.25,1,0.5,1) forwards;
}
@keyframes rise-in{to{opacity:1;transform:translateY(0)}}
.main-content > .stagger-item:nth-child(1){animation-delay:0.30s}
.main-content > .stagger-item:nth-child(2){animation-delay:0.42s}
.main-content > .stagger-item:nth-child(3){animation-delay:0.54s}
.main-content > .stagger-item:nth-child(4){animation-delay:0.66s}
.main-content > .stagger-item:nth-child(5){animation-delay:0.78s}
.main-content > .stagger-item:nth-child(6){animation-delay:0.90s}
.main-content > .stagger-item:nth-child(7){animation-delay:1.02s}
.main-content > .stagger-item:nth-child(8){animation-delay:1.14s}
```

(This reproduces the `300 + i*120`ms stagger that `skipToMain()`/`transitionToMain()` produced in JS. nth-child(8) is for the footer added in Task 9.)

- [ ] **Step 4: Make reduced-motion show content instantly**

Replace:

```css
@media (prefers-reduced-motion:reduce){
  *,*::before,*::after{
    animation-duration:0.01ms !important;
    transition-duration:0.01ms !important;
  }
}
```

with:

```css
@media (prefers-reduced-motion:reduce){
  *,*::before,*::after{
    animation-duration:0.01ms !important;
    animation-delay:0.01ms !important;
    transition-duration:0.01ms !important;
  }
}
```

- [ ] **Step 5: Delete ceremony HTML**

Delete each block entirely:

1. `<body data-state="boot">` → `<body>` (attribute only).
2. The first hidden-SVG block: `<!-- SVG filters (hidden) -->` plus the whole `<svg width="0" height="0" style="position:absolute">...</svg>` containing `#paper-grain`, `#stamp-emboss`, `#stamp-worn` (lines 776-822). Do NOT delete the later one-line `<svg ...><filter id="page-grain-filter"...></svg>` (line 834) - the background grain needs it.
3. `<!-- ===== Envelope Scene ===== -->` through the closing `</div>` of `<div id="scene-envelope" ...>` (lines 837-917).
4. `<!-- SVG defs for icon animation (must be outside scene for Chrome to resolve refs when scene is hidden) -->` plus its whole `<svg ...>...</svg>` (lines 919-969).
5. `<!-- ===== Reveal Scene (R icon animation) ===== -->` through the closing `</div>` of `#scene-reveal` (lines 971-1015).
6. The replay button: `<button class="replay-link" id="replay-link" type="button">` through its `</button>` (lines 1088-1091).
7. `<!-- Mobile Gate -->` through `</section>` of `#scene-mobile` (lines 1094-1102).
8. `<div class="debug-hint" id="debug-hint">Click to continue</div>` (line 1104).
9. The entire main ceremony script: the `<script>` that begins `(function(){` / `'use strict';` (line 1106) through its `</script>` (line 1732). Keep the two scripts after it (`<!-- FAQ accordion animation -->` and `<!-- Dust particles -->`).

- [ ] **Step 6: Activate the main scene statically**

Replace `<main id="scene-main" class="scene">` with `<main id="scene-main" class="scene active">`.

- [ ] **Step 7: Verify no ceremony remnants**

```bash
cd $REPO_ROOT/.worktrees/main-landing-page
grep -cE 'scene-envelope|scene-reveal|scene-mobile|replay-link|debug-hint|hold-btn|stamp|env-|letter-|paper-noise|wax-seal|is-safari|data-state|runCeremony|skipToMain|rv-|reveal-canvas|mobile-|signature\.png' website/index.html || echo "CLEAN"
grep -c 'stagger-item' website/index.html
grep -c 'page-grain-filter' website/index.html
```

Expected: `CLEAN` (grep exits nonzero = 0 matches), stagger-item count ≥ 8, page-grain-filter count 2 (filter def + inline style).

- [ ] **Step 8: Verify in browser**

```bash
python3 -m http.server 8080 --directory website
```

Open `http://localhost:8080/` in the browser. Expected: page content (icon, "Remarc Early Access" title, video iframe, download button, feedback, FAQ) appears immediately with the short stagger - no envelope, no R animation, no replay button. Background nebula/halo/dust all animate. Console shows zero errors. FAQ items open/close with animation.

- [ ] **Step 9: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): strip invite ceremony, land straight in final state"
```

---

### Task 3: Head, meta, and SoftwareApplication JSON-LD

**Files:**
- Modify: `website/index.html` (head block only)

**Interfaces:**
- Produces: indexable head with canonical/OG/Twitter meta and one `application/ld+json` SoftwareApplication script. Task 8 adds a second ld+json script (FAQPage) after it.

- [ ] **Step 1: Replace the meta/title/link block**

Replace invite head lines (from `<meta name="robots" content="noindex, noarchive, nofollow">` through `<link rel="apple-touch-icon" href="/apple-touch-icon.png">`, keeping charset and viewport above them) with:

```html
<meta name="robots" content="index, follow">
<meta name="theme-color" content="#0a0a0c">
<meta name="description" content="Remarc is the feedback layer between you and your coding agent. Point at anything on your Mac - text, screenshots, web elements, voice - and your agent reads and resolves your comments over MCP. Free and open source.">
<meta property="og:title" content="Remarc">
<meta property="og:description" content="The feedback layer between you and your coding agent.">
<meta property="og:type" content="website">
<meta property="og:url" content="https://remarc.app">
<meta property="og:image" content="https://releases.remarc.app/icon_256x256.png">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="Remarc">
<meta name="twitter:description" content="The feedback layer between you and your coding agent.">
<title>Remarc - The feedback layer between you and your coding agent</title>
<link rel="canonical" href="https://remarc.app/">
<link rel="icon" type="image/png" href="/favicon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preload" href="https://releases.remarc.app/icon_256x256.png" as="image" fetchpriority="high">
```

- [ ] **Step 2: Add SoftwareApplication JSON-LD**

Insert directly after the preload link, before `<style>`:

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Remarc",
  "operatingSystem": "macOS 14.0+",
  "applicationCategory": "DeveloperApplication",
  "description": "Remarc is the feedback layer between you and your coding agent. Point at anything on your Mac - text, screenshots, web elements, voice - and your agent reads and resolves your comments over MCP. Free and open source.",
  "url": "https://remarc.app",
  "downloadUrl": "https://remarc.app/download",
  "author": {
    "@type": "Organization",
    "name": "Metedata",
    "url": "https://metedata.com"
  },
  "offers": {
    "@type": "Offer",
    "price": "0",
    "priceCurrency": "USD"
  }
}
</script>
```

- [ ] **Step 3: Verify**

```bash
grep -c 'noindex' website/index.html   # expect 0 (command exits 1)
python3 - <<'EOF'
import json, re
html = open('website/index.html').read()
blocks = re.findall(r'<script type="application/ld\+json">\s*(.*?)\s*</script>', html, re.S)
assert len(blocks) == 1, f"expected 1 ld+json block, got {len(blocks)}"
data = json.loads(blocks[0])
assert data["@type"] == "SoftwareApplication" and data["offers"]["price"] == "0"
print("JSON-LD OK")
EOF
```

Expected: `0` matches for noindex, `JSON-LD OK`.

- [ ] **Step 4: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): public head - indexable meta, OG, canonical, SoftwareApplication JSON-LD"
```

---

### Task 4: Hero - title, subtitle, icon tilt+shine

**Files:**
- Modify: `website/index.html` (header markup, `.app-icon` CSS, new tilt script)

**Interfaces:**
- Consumes: static page from Task 2.
- Produces: `.hero-icon-wrapper` > `.app-icon` + `.hero-icon-shine` structure; `.tilt-active` class contract; the tilt `<script>` placed immediately before the `<!-- FAQ accordion animation -->` comment. Task 10 adds the mobile icon sizes.

- [ ] **Step 1: Replace the header markup**

Replace:

```html
    <header class="stagger-item" style="display:flex;flex-direction:column;align-items:center;gap:12px;width:100%">
      <div class="app-icon">
        <img src="https://releases.remarc.app/icon_256x256.png" alt="Remarc" width="64" height="64">
      </div>
      <h1 class="main-title">Remarc Early Access</h1>
      <p class="main-subtitle">Watch the video below to learn about Remarc.</p>
    </header>
```

with:

```html
    <header class="stagger-item" style="display:flex;flex-direction:column;align-items:center;gap:12px;width:100%">
      <div class="hero-icon-wrapper">
        <div class="app-icon">
          <img src="https://releases.remarc.app/icon_256x256.png" alt="Remarc" width="96" height="96">
        </div>
        <div class="hero-icon-shine"></div>
      </div>
      <h1 class="main-title">Remarc</h1>
      <p class="main-subtitle">The feedback layer between you and your coding agent.</p>
    </header>
```

- [ ] **Step 2: Replace the icon CSS**

Replace:

```css
.app-icon{
  width:64px;height:64px;border-radius:16px;
  overflow:hidden;margin:0 auto 28px;
  box-shadow:0 4px 16px rgba(0,0,0,0.3);
}
.app-icon img{width:100%;height:100%;display:block}
```

with (ported from Relinq, sizes adapted 160→96, shine circle 120→72):

```css
/* App icon with 3D tilt + cursor shine (ported from the Relinq landing page) */
.hero-icon-wrapper{
  perspective:1000px;
  display:inline-block;
  position:relative;
  margin:0 auto 28px;
  /* Shadow on wrapper: overflow/border-radius on the icon would clip its own filter */
  filter:drop-shadow(0 12px 24px rgba(0,0,0,0.4));
}
.app-icon{
  width:96px;height:96px;border-radius:19px;
  overflow:hidden;
  transition:transform 0.15s ease-out;
  transform:perspective(1000px) rotateX(0deg) rotateY(0deg) scale3d(1,1,1);
  will-change:transform;
}
.app-icon img{width:100%;height:100%;display:block}
.hero-icon-shine{
  position:absolute;top:0;left:0;
  width:96px;height:96px;border-radius:19px;
  pointer-events:none;opacity:0;
  transition:transform 0.15s ease-out,opacity 0.2s ease;
  transform:perspective(1000px) rotateX(0deg) rotateY(0deg) scale3d(1,1,1);
  will-change:transform,opacity;
  background:radial-gradient(
    circle 72px at var(--shine-x,50%) var(--shine-y,50%),
    rgba(255,255,255,0.06) 0%,
    rgba(255,255,255,0.02) 50%,
    transparent 100%
  );
}
.hero-icon-wrapper.tilt-active .hero-icon-shine{opacity:1}
```

- [ ] **Step 3: Add the tilt script**

Insert immediately before the `<!-- FAQ accordion animation -->` comment:

```html
<!-- Icon tilt + shine (desktop only) -->
<script>
(function(){
  var wrapper=document.querySelector('.hero-icon-wrapper');
  if(!wrapper)return;
  var icon=wrapper.querySelector('.app-icon');
  var shine=wrapper.querySelector('.hero-icon-shine');
  if(!icon)return;
  if(window.matchMedia('(hover: none)').matches)return;
  var maxTilt=8;
  wrapper.addEventListener('mousemove',function(e){
    var rect=wrapper.getBoundingClientRect();
    var x=Math.max(0,Math.min(1,(e.clientX-rect.left)/rect.width));
    var y=Math.max(0,Math.min(1,(e.clientY-rect.top)/rect.height));
    var rotateY=(0.5-x)*2*maxTilt;
    var rotateX=(y-0.5)*2*maxTilt;
    var t='perspective(1000px) rotateX('+rotateX+'deg) rotateY('+rotateY+'deg) scale3d(1.02,1.02,1.02)';
    icon.style.transform=t;
    if(shine){
      shine.style.setProperty('--shine-x',(x*100)+'%');
      shine.style.setProperty('--shine-y',(y*100)+'%');
      shine.style.transform=t;
    }
  });
  wrapper.addEventListener('mouseenter',function(){wrapper.classList.add('tilt-active')});
  wrapper.addEventListener('mouseleave',function(){
    var r='perspective(1000px) rotateX(0deg) rotateY(0deg) scale3d(1,1,1)';
    icon.style.transform=r;
    if(shine)shine.style.transform=r;
    wrapper.classList.remove('tilt-active');
  });
})();
</script>
```

- [ ] **Step 4: Verify in browser**

With the Task 2 server still running, reload `http://localhost:8080/`. Expected: title reads "Remarc", subtitle reads "The feedback layer between you and your coding agent.", icon renders at 96px. Move the cursor over the icon: it tilts toward the cursor with a subtle light spot following the pointer, springs back on leave. Console error-free.

- [ ] **Step 5: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): Remarc hero with tilt+shine icon and release subtitle"
```

---

### Task 5: Launch video assets to R2

**Files:**
- No repo files. Produces two R2 objects:
  - `https://releases.remarc.app/media/remarc-launch.mp4`
  - `https://releases.remarc.app/media/remarc-launch-poster.jpg`

**Interfaces:**
- Produces: the two URLs above, consumed verbatim by Task 6.

- [ ] **Step 1: Extract poster candidates**

```bash
SRC="/path/to/remarc-hero-animation/renders/2026-08-06-soundtrack-1920.mp4"
OUT="$(mktemp -d)"
for t in 5 20 44; do ffmpeg -y -ss "$t" -i "$SRC" -frames:v 1 -q:v 2 "$OUT/poster-$t.jpg" 2>/dev/null; done
ls -lh "$OUT"
echo "$OUT"
```

Expected: three JPGs, each roughly 100-400 KB.

- [ ] **Step 2: Pick the poster**

View all three candidates (the Read tool renders images). Pick the cleanest, most representative frame: prefer a composed frame (product name lockup or a clear product shot), avoid mid-motion blur or half-transitioned text. Copy the chosen one:

```bash
cp "$OUT/poster-44.jpg" "$OUT/remarc-launch-poster.jpg"   # substitute the chosen timestamp
```

- [ ] **Step 3: Check wrangler auth**

```bash
npx wrangler whoami
```

Expected: an account email/name (the Cloudflare account owning the `remarc-releases` bucket). **If this reports not-authenticated: STOP this task and report to the user** - they need to run `wrangler login` (or set `CLOUDFLARE_API_TOKEN`); include the exact upload commands from Step 4 in the report. Tasks 6-9 can proceed regardless; final verification (Task 11) requires these uploads live.

- [ ] **Step 4: Upload both objects**

```bash
npx wrangler r2 object put remarc-releases/media/remarc-launch.mp4 --file="$SRC" --content-type video/mp4 --remote
npx wrangler r2 object put remarc-releases/media/remarc-launch-poster.jpg --file="$OUT/remarc-launch-poster.jpg" --content-type image/jpeg --remote
```

(If the installed wrangler version rejects `--remote`, drop the flag - older versions upload remotely by default.)

- [ ] **Step 5: Verify live**

```bash
curl -sI https://releases.remarc.app/media/remarc-launch.mp4 | head -4
curl -sI https://releases.remarc.app/media/remarc-launch-poster.jpg | head -4
```

Expected: both `HTTP/2 200`, content types `video/mp4` and `image/jpeg`, mp4 size ~14 MB.

---

### Task 6: Self-hosted video embed

**Files:**
- Modify: `website/index.html` (video markup + `.video-wrap` CSS)

**Interfaces:**
- Consumes: URLs from Task 5 (page edits proceed even if Task 5 is blocked on auth).
- Produces: `.video-wrap video` element replacing the YouTube iframe.

- [ ] **Step 1: Replace the iframe markup**

Replace:

```html
    <div class="video-wrap stagger-item">
      <iframe src="https://www.youtube.com/embed/nSVH2Yqr6t0" title="Remarc Demo" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
    </div>
```

with:

```html
    <div class="video-wrap stagger-item">
      <video controls playsinline preload="metadata" poster="https://releases.remarc.app/media/remarc-launch-poster.jpg">
        <source src="https://releases.remarc.app/media/remarc-launch.mp4" type="video/mp4">
        Your browser does not support the video tag.
      </video>
    </div>
```

(No autoplay: the video has a soundtrack, so it is click-to-play with sound.)

- [ ] **Step 2: Update the video CSS**

Replace:

```css
.video-wrap{
  width:100%;aspect-ratio:16/9;
  background:rgba(12,13,18,0.95);border:1px solid rgba(99,102,241,0.1);
  border-radius:12px;display:flex;align-items:center;justify-content:center;
  flex-direction:column;gap:12px;overflow:hidden;
}
.video-wrap iframe{width:100%;height:100%;border:none;border-radius:12px}
```

with (aspect corrected to the render's 1920x1200 = 16:10):

```css
.video-wrap{
  width:100%;aspect-ratio:16/10;
  background:rgba(12,13,18,0.95);border:1px solid rgba(99,102,241,0.1);
  border-radius:12px;overflow:hidden;
}
.video-wrap video{width:100%;height:100%;display:block;border-radius:12px;object-fit:cover}
```

- [ ] **Step 3: Verify**

```bash
grep -c 'youtube' website/index.html   # expect 0 (exit 1)
```

Reload `http://localhost:8080/`. Expected (with Task 5 done): poster frame shows in a 16:10 rounded frame; clicking play starts the video WITH sound; native controls work. If Task 5 is still blocked, expected: dark empty 16:10 frame with native controls, no console error other than the two 404s for the media URLs - note it and continue.

- [ ] **Step 4: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): self-hosted launch video, 16:10 frame, click-to-play with sound"
```

---

### Task 7: Dual CTA row + star chip

**Files:**
- Modify: `website/index.html` (download-section markup, CTA CSS, star-fetch script)

**Interfaces:**
- Consumes: `.download-section` block from the seeded page; `--indigo*` vars; `[hidden]` rule.
- Produces: `.cta-row`, `.cta-btn`, `.cta-primary`, `.cta-secondary`, `.star-chip` classes and `#star-chip` element; a mobile `@media (max-width:768px)` block at the END of the stylesheet that Task 10 extends.

- [ ] **Step 1: Replace the download-section markup**

Replace:

```html
    <div class="download-section stagger-item">
      <a href="/download" class="cta-download">
        <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M11.182.008C11.148-.03 9.923.023 8.857 1.18c-1.066 1.156-.902 2.482-.878 2.516s1.52.087 2.475-1.258.762-2.391.728-2.43m3.314 11.733c-.048-.096-2.325-1.234-2.113-3.422s1.675-2.789 1.698-2.854-.597-.79-1.254-1.157a3.7 3.7 0 0 0-1.563-.434c-.108-.003-.483-.095-1.254.116-.508.139-1.653.589-1.968.607-.316.018-1.256-.522-2.267-.665-.647-.125-1.333.131-1.824.328-.49.196-1.422.754-2.074 2.237-.652 1.482-.311 3.83-.067 4.56s.625 1.924 1.273 2.796c.576.984 1.34 1.667 1.659 1.899s1.219.386 1.843.067c.502-.308 1.408-.485 1.766-.472.357.013 1.061.154 1.782.539.571.197 1.111.115 1.652-.105.541-.221 1.324-1.059 2.238-2.758q.52-1.185.473-1.282"/></svg>
        Download for macOS
      </a>
      <span class="version-text">Requires macOS 14.0+</span>
    </div>
```

with:

```html
    <div class="download-section stagger-item">
      <div class="cta-row">
        <a href="/download" class="cta-btn cta-primary">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M11.182.008C11.148-.03 9.923.023 8.857 1.18c-1.066 1.156-.902 2.482-.878 2.516s1.52.087 2.475-1.258.762-2.391.728-2.43m3.314 11.733c-.048-.096-2.325-1.234-2.113-3.422s1.675-2.789 1.698-2.854-.597-.79-1.254-1.157a3.7 3.7 0 0 0-1.563-.434c-.108-.003-.483-.095-1.254.116-.508.139-1.653.589-1.968.607-.316.018-1.256-.522-2.267-.665-.647-.125-1.333.131-1.824.328-.49.196-1.422.754-2.074 2.237-.652 1.482-.311 3.83-.067 4.56s.625 1.924 1.273 2.796c.576.984 1.34 1.667 1.659 1.899s1.219.386 1.843.067c.502-.308 1.408-.485 1.766-.472.357.013 1.061.154 1.782.539.571.197 1.111.115 1.652-.105.541-.221 1.324-1.059 2.238-2.758q.52-1.185.473-1.282"/></svg>
          Download for macOS
        </a>
        <a href="https://github.com/metedata/Remarc" class="cta-btn cta-secondary" target="_blank" rel="noopener" aria-label="Remarc on GitHub">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>
          GitHub
          <span class="star-chip" id="star-chip" hidden></span>
        </a>
      </div>
      <span class="version-text">Requires macOS 14.0 or later</span>
    </div>
```

- [ ] **Step 2: Replace the CTA CSS**

Replace the whole `.cta-download{...}` group (from `.cta-download{` through `.cta-download svg{flex-shrink:0}`, invite lines 551-563) with:

```css
.cta-row{display:flex;gap:12px;justify-content:center;flex-wrap:wrap}
.cta-btn{
  display:inline-flex;align-items:center;justify-content:center;gap:8px;
  padding:16px 20px;
  font-size:15px;font-weight:600;letter-spacing:0.3px;
  border-radius:12px;cursor:pointer;text-decoration:none;
  transition:background 0.2s,transform 0.15s,box-shadow 0.2s,border-color 0.2s;
  min-height:48px;width:240px;
}
.cta-btn svg{flex-shrink:0}
.cta-btn:focus-visible{outline:none;box-shadow:0 0 0 3px rgba(99,102,241,0.4)}
.cta-primary{
  background:var(--indigo);color:#fff;
  border:1px solid rgba(255,255,255,0.1);
  box-shadow:0 2px 8px rgba(99,102,241,0.25),0 0 24px rgba(99,102,241,0.08),inset 0 1px 0 rgba(255,255,255,0.1);
}
.cta-primary:hover{background:var(--indigo-hover);transform:translateY(-1px);box-shadow:0 4px 16px rgba(99,102,241,0.35),0 0 32px rgba(99,102,241,0.12)}
.cta-primary:active{background:var(--indigo-active);transform:translateY(0)}
.cta-secondary{
  background:rgba(255,255,255,0.03);color:rgba(255,255,255,0.85);
  border:1px solid rgba(99,102,241,0.35);
}
.cta-secondary:hover{background:rgba(99,102,241,0.12);border-color:rgba(99,102,241,0.55);transform:translateY(-1px)}
.cta-secondary:active{background:rgba(99,102,241,0.18);transform:translateY(0)}
.star-chip{
  display:inline-flex;align-items:center;
  padding:2px 8px;border-radius:999px;
  background:rgba(255,255,255,0.08);
  font-size:12px;font-weight:500;color:rgba(255,255,255,0.7);
}
```

Then add at the very end of the `<style>` block (immediately before `</style>`, after the reduced-motion media query):

```css
@media (max-width:768px){
  .cta-row{flex-direction:column;width:100%;max-width:320px;margin:0 auto}
  .cta-btn{width:100%}
}
```

- [ ] **Step 3: Add the star-count script**

Insert immediately before the `<!-- Icon tilt + shine (desktop only) -->` comment:

```html
<!-- GitHub star count (chip hidden below threshold or on failure) -->
<script>
(function(){
  var chip=document.getElementById('star-chip');
  if(!chip||!window.fetch)return;
  var KEY='gh-stars:metedata/Remarc',TTL=3600000,THRESHOLD=25;
  function show(n){
    if(typeof n!=='number'||n<THRESHOLD)return;
    chip.textContent='★ '+new Intl.NumberFormat('en',{notation:'compact',maximumFractionDigits:1}).format(n);
    chip.hidden=false;
    chip.closest('a').setAttribute('aria-label','Remarc on GitHub, '+n.toLocaleString('en')+' stars');
  }
  var cached=null;
  try{cached=JSON.parse(localStorage.getItem(KEY))}catch(_e){}
  if(cached&&typeof cached.n==='number'&&Date.now()-cached.t<TTL){show(cached.n);return}
  fetch('https://api.github.com/repos/metedata/Remarc',{headers:{Accept:'application/vnd.github+json'}})
    .then(function(r){if(!r.ok)throw new Error('http '+r.status);return r.json()})
    .then(function(d){
      try{localStorage.setItem(KEY,JSON.stringify({t:Date.now(),n:d.stargazers_count}))}catch(_e){}
      show(d.stargazers_count);
    })
    .catch(function(){if(cached&&typeof cached.n==='number')show(cached.n)});
})();
</script>
```

- [ ] **Step 4: Verify buttons in browser**

Reload `http://localhost:8080/`. Expected: two buttons side by side, visually identical width (both 240px) and pill shape; primary indigo with Apple logo, secondary ghost with GitHub mark; both lift 1px on hover with distinct hover styles and press back on click. The star chip is NOT visible (repo is private → fetch 404s silently; console may log the failed request, no uncaught errors). At ≤768px width the buttons stack full-width.

- [ ] **Step 5: Verify the chip logic with a high-star repo**

Temporarily change BOTH occurrences of `metedata/Remarc` in the star script (`KEY` and the fetch URL) to `microsoft/vscode`, hard-reload. Expected: chip appears inside the GitHub button as `★ 175K`-style compact text, and the link's `aria-label` reads "Remarc on GitHub, <full number> stars". Then revert both to `metedata/Remarc`, hard-reload (and `localStorage.clear()` in console), confirm chip hidden again.

```bash
grep -c 'microsoft/vscode' website/index.html   # expect 0 after revert (exit 1)
grep -c 'metedata/Remarc' website/index.html    # expect 3 (href + KEY + fetch URL)
```

- [ ] **Step 6: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): dual Download/GitHub CTAs with auto-hiding star chip"
```

---

### Task 8: FAQ rewrite + FAQPage JSON-LD

**Files:**
- Modify: `website/index.html` (faq-list contents; second ld+json script in head)

**Interfaces:**
- Consumes: `.faq-item`/`.faq-answer-wrap` accordion structure and script (kept from invite page - the markup pattern per item must stay identical for the animation script to work).
- Produces: 8 FAQ items; FAQPage JSON-LD placed directly after the SoftwareApplication ld+json script from Task 3.

- [ ] **Step 1: Replace the FAQ items**

Replace everything inside `<div class="faq-list">...</div>` (the seven existing `<details class="faq-item">` blocks) with these eight:

```html
        <details class="faq-item">
          <summary>What is Remarc?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">Remarc is a contextual feedback layer for AI agents. It lives in your menu bar and lets you leave comments, screenshots, and voice critiques on anything on your screen - then your AI agent sees it all with full context via MCP. It's the missing input channel between you and your agent.</div></div>
        </details>
        <details class="faq-item">
          <summary>How much does Remarc cost?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">Remarc is free and open source under the MIT license. There are no accounts, no subscriptions, and no paid tiers - just download it and start commenting. If you find it useful, starring the <a href="https://github.com/metedata/Remarc" target="_blank" rel="noopener">GitHub repository</a> helps more people discover it.</div></div>
        </details>
        <details class="faq-item">
          <summary>Which coding agents does it work with?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">Claude Code and Codex connect through the Remarc plugin, and Cursor is set up directly from the app's preferences. Under the hood it's all MCP, so any agent that supports MCP can read your comments, work through them, and mark them resolved.</div></div>
        </details>
        <details class="faq-item">
          <summary>Why not just type everything into my agent's chat?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">Describing what you see is slow and lossy. Remarc captures the thing itself - the selected text, the source app, the screenshot region, the web element - along with your comment, so your agent works from structured context instead of a paraphrase. It's the difference between writing a bug report and pointing at the bug.</div></div>
        </details>
        <details class="faq-item">
          <summary>Is my data private?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">Yes. Your comments live in a local file on your Mac and never leave your machine. There are no accounts, no telemetry, and no cloud servers - your agent reads comments through a local MCP server, and voice transcription runs on-device.</div></div>
        </details>
        <details class="faq-item">
          <summary>How do I get the Chrome extension?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">The Remarc Chrome extension lets you leave comments directly on web pages and automatically attaches web context - like the page URL, selected text, and surrounding content - so your AI agent has the full picture. Since it's not on the Chrome Web Store yet, you'll need to install it manually - it only takes a minute. Head to the <a href="/chrome-extension">Chrome extension page</a> for the download and setup instructions.</div></div>
        </details>
        <details class="faq-item">
          <summary>Where can I learn more?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">The <a href="/docs">documentation</a> covers setup, agent integrations, and every feature in detail. The <a href="https://github.com/metedata/Remarc" target="_blank" rel="noopener">GitHub repository</a> has the source code and release notes.</div></div>
        </details>
        <details class="faq-item">
          <summary>How do I provide feedback?</summary>
          <div class="faq-answer-wrap"><div class="faq-answer">Found a bug or have an idea? Open an issue on <a href="https://github.com/metedata/Remarc" target="_blank" rel="noopener">GitHub</a>. You can also use the Send Feedback button built into Remarc - right-click the menu bar icon or find it in Settings - or reach out via <a href="mailto:mete@metedata.com">email</a>, on <a href="https://x.com/metedata" target="_blank" rel="noopener">X</a>, or on <a href="https://www.threads.net/@young.mete" target="_blank" rel="noopener">Threads</a>.</div></div>
        </details>
```

Staleness check while here: open `website/chrome-extension/index.html` (in the worktree) and confirm it still describes manual installation. If the extension has since shipped to the Chrome Web Store, update FAQ item 6's answer to link the store listing instead and note the change in the commit message.

- [ ] **Step 2: Add FAQPage JSON-LD**

Insert directly after the SoftwareApplication `</script>` in the head:

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
    {"@type": "Question", "name": "What is Remarc?", "acceptedAnswer": {"@type": "Answer", "text": "Remarc is a contextual feedback layer for AI agents. It lives in your menu bar and lets you leave comments, screenshots, and voice critiques on anything on your screen - then your AI agent sees it all with full context via MCP. It's the missing input channel between you and your agent."}},
    {"@type": "Question", "name": "How much does Remarc cost?", "acceptedAnswer": {"@type": "Answer", "text": "Remarc is free and open source under the MIT license. There are no accounts, no subscriptions, and no paid tiers - just download it and start commenting."}},
    {"@type": "Question", "name": "Which coding agents does it work with?", "acceptedAnswer": {"@type": "Answer", "text": "Claude Code and Codex connect through the Remarc plugin, and Cursor is set up directly from the app's preferences. Under the hood it's all MCP, so any agent that supports MCP can read your comments, work through them, and mark them resolved."}},
    {"@type": "Question", "name": "Why not just type everything into my agent's chat?", "acceptedAnswer": {"@type": "Answer", "text": "Describing what you see is slow and lossy. Remarc captures the thing itself - the selected text, the source app, the screenshot region, the web element - along with your comment, so your agent works from structured context instead of a paraphrase. It's the difference between writing a bug report and pointing at the bug."}},
    {"@type": "Question", "name": "Is my data private?", "acceptedAnswer": {"@type": "Answer", "text": "Yes. Your comments live in a local file on your Mac and never leave your machine. There are no accounts, no telemetry, and no cloud servers - your agent reads comments through a local MCP server, and voice transcription runs on-device."}},
    {"@type": "Question", "name": "How do I get the Chrome extension?", "acceptedAnswer": {"@type": "Answer", "text": "The Remarc Chrome extension lets you leave comments directly on web pages and automatically attaches web context - like the page URL, selected text, and surrounding content. It is not on the Chrome Web Store yet, so it is installed manually from the Chrome extension page at remarc.app/chrome-extension."}},
    {"@type": "Question", "name": "Where can I learn more?", "acceptedAnswer": {"@type": "Answer", "text": "The documentation at remarc.app/docs covers setup, agent integrations, and every feature in detail. The GitHub repository has the source code and release notes."}},
    {"@type": "Question", "name": "How do I provide feedback?", "acceptedAnswer": {"@type": "Answer", "text": "Open an issue on GitHub, use the Send Feedback button built into Remarc, or reach out via email, X, or Threads."}}
  ]
}
</script>
```

(If Step 1's staleness check changed the Chrome extension answer, mirror the change here.)

- [ ] **Step 3: Verify**

```bash
grep -c '<details class="faq-item">' website/index.html   # expect 8
grep -c '—' website/index.html                            # expect 0 (exit 1) - no em dashes anywhere
python3 - <<'EOF'
import json, re
html = open('website/index.html').read()
blocks = re.findall(r'<script type="application/ld\+json">\s*(.*?)\s*</script>', html, re.S)
assert len(blocks) == 2, f"expected 2 ld+json blocks, got {len(blocks)}"
faq = json.loads(blocks[1])
assert faq["@type"] == "FAQPage" and len(faq["mainEntity"]) == 8
print("FAQ JSON-LD OK")
EOF
```

Reload the page: all 8 items render, open/close animation still works (the accordion script binds per `.faq-item`), links inside answers are indigo and clickable. Removed questions ("How should I test it?", "What kind of feedback are you looking for?", "Can I post about it?") are gone.

- [ ] **Step 4: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): public FAQ set with FAQPage JSON-LD"
```

---

### Task 9: Footer

**Files:**
- Modify: `website/index.html` (new footer markup + CSS)

**Interfaces:**
- Consumes: `.main-content` (footer becomes its 8th child, picking up the Task 2 `nth-child(8)` stagger delay).
- Produces: `.site-footer` element - the page's docs link home (with FAQ item 7).

- [ ] **Step 1: Add footer markup**

Insert immediately after the closing `</div>` of `<div class="faq-section stagger-item">` (still inside `<div class="main-content">`):

```html
    <footer class="site-footer stagger-item">
      <nav class="footer-links" aria-label="Footer">
        <a href="/docs">Documentation</a>
        <span class="footer-sep" aria-hidden="true">&middot;</span>
        <a href="https://github.com/metedata/Remarc" target="_blank" rel="noopener">GitHub</a>
        <span class="footer-sep" aria-hidden="true">&middot;</span>
        <a href="mailto:mete@metedata.com">Contact</a>
        <span class="footer-sep" aria-hidden="true">&middot;</span>
        <span class="footer-copy">&copy; 2026 Metedata</span>
      </nav>
    </footer>
```

- [ ] **Step 2: Add footer CSS**

Insert after the `.faq-answer a:hover{...}` rule:

```css
/* ===== Footer ===== */
.site-footer{margin-top:16px;padding-bottom:8px}
.footer-links{
  display:flex;align-items:center;justify-content:center;gap:10px;flex-wrap:wrap;
  font-size:12px;color:rgba(255,255,255,0.25);
}
.footer-links a{color:rgba(255,255,255,0.35);text-decoration:none;transition:color 0.2s}
.footer-links a:hover{color:rgba(255,255,255,0.6)}
.footer-sep{color:rgba(255,255,255,0.15)}
```

- [ ] **Step 3: Verify**

Reload the page and scroll to the bottom. Expected: one quiet line "Documentation · GitHub · Contact · © 2026 Metedata"; links brighten on hover; footer staggers in last on load. Verify child order:

```bash
python3 - <<'EOF'
import re
html = open('website/index.html').read()
main = re.search(r'<div class="main-content"[^>]*>(.*)</div>\s*</main>', html, re.S).group(1)
classes = re.findall(r'<(?:header|div|footer) class="([^"]*stagger-item[^"]*)"', main)
assert len(classes) == 8, f"expected 8 stagger children, got {len(classes)}"
print("8 stagger children OK")
EOF
```

- [ ] **Step 4: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): minimal footer with docs, GitHub, contact links"
```

---

### Task 10: Responsive + reduced-motion + dead-code sweep

**Files:**
- Modify: `website/index.html` (mobile media query additions; any orphan cleanup)

**Interfaces:**
- Consumes: the `@media (max-width:768px)` block Task 7 added at the end of the stylesheet.

- [ ] **Step 1: Add mobile icon sizing**

Inside the existing `@media (max-width:768px){...}` block, after the `.cta-btn{width:100%}` rule, add:

```css
  .app-icon,.hero-icon-shine{width:80px;height:80px;border-radius:16px}
```

- [ ] **Step 2: Verify mobile viewport**

Resize the browser to the mobile preset (375px wide) and reload `http://localhost:8080/`. Expected: NO desktop-only gate of any kind - the real page renders; icon 80px; title/subtitle scale down (existing clamp() handles this); CTAs stacked full-width; video full-width; FAQ readable; footer wraps gracefully; horizontal scrolling absent. Tilt does not activate (mobile emulation = `hover: none`).

- [ ] **Step 3: Verify reduced motion**

Emulate `prefers-reduced-motion: reduce` (browser dev tools rendering emulation), reload. Expected: all content visible immediately (no 1s stagger wait), page fully usable.

- [ ] **Step 4: No-JS sanity**

```bash
curl -s http://localhost:8080/ | grep -c 'href="/download"'                      # expect 1
curl -s http://localhost:8080/ | grep -c 'href="https://github.com/metedata/Remarc"'  # expect ≥3 (CTA, FAQ answers, footer)
```

Both CTAs are plain anchors - they work with JS disabled; the chip and tilt are progressive enhancements.

- [ ] **Step 5: Dead-code sweep**

```bash
grep -cE 'cta-download|play-icon|video-placeholder|EASE_EXPO|HOLD_|STAMP_|--paper-|--ink|--env-w|--letter-w|--ease-expo|youtube|noindex' website/index.html || echo "CLEAN"
```

Expected: `CLEAN`. If any match, delete the orphaned rule/reference it points to.

- [ ] **Step 6: Commit**

```bash
git add website/index.html
git commit -m "feat(landing): responsive mobile layout, reduced-motion and no-JS hardening"
```

---

### Task 11: Full verification sweep

**Files:** none (verification only; fixes committed if found)

- [ ] **Step 1: Isolation check - only the landing page changed**

```bash
cd $REPO_ROOT/.worktrees/main-landing-page
git diff --stat main...HEAD            # expect exactly one file: website/index.html
git diff main...HEAD -- website/invite # expect empty output
```

- [ ] **Step 2: Spec walkthrough against the live local page**

Open `http://localhost:8080/` at desktop size and confirm each line:

- Title "Remarc"; subtitle "The feedback layer between you and your coding agent."
- No intro animation, no replay button; subtle stagger only; background nebula + rotating halo + dust particles + grain all present and animating.
- Icon 96px, tilts toward cursor with shine, resets on leave.
- Video: poster visible, click-to-play WITH sound, native controls, 16:10, rounded dark frame (requires Task 5 uploads live).
- CTAs: equal width/shape; hover and active states on both; GitHub button opens `https://github.com/metedata/Remarc` in a new tab; star chip hidden (until repo is public and past 25 stars).
- Feedback section unchanged (email/X/Threads icons work).
- FAQ: 8 items, correct set, accordion animates, links work.
- Footer: Documentation · GitHub · Contact · © 2026 Metedata.
- Console: no uncaught errors (the GitHub API 404 is an expected handled failure while the repo is private).

- [ ] **Step 3: Structured data + infra checks**

```bash
python3 - <<'EOF'
import json, re
html = open('website/index.html').read()
for b in re.findall(r'<script type="application/ld\+json">\s*(.*?)\s*</script>', html, re.S):
    json.loads(b)
print("All JSON-LD parses")
EOF
curl -sI https://remarc.app/download | grep -iE 'HTTP|location'   # expect 302 to current Remarc-x.y.z.zip
```

- [ ] **Step 4: Screenshots for the user**

Capture desktop (1280px) and mobile (375px) full-page screenshots and send them to the user as the visual deliverable.

- [ ] **Step 5: Report launch-coordination reminders**

Include in the final report: (1) page deploys when merged to main (Cloudflare Pages) - coordinate with flipping `metedata/Remarc` public; (2) `/docs` returns 404 until the documentation page ships; (3) confirm the R2 media uploads completed (Task 5).

---

## Out of scope (per spec)

Analytics, the `/docs` page itself, a designed og-image, any change to `website/invite/`, `/download` mechanics, or the release pipeline. Merge/branch integration is handled after this plan completes (superpowers:finishing-a-development-branch).
