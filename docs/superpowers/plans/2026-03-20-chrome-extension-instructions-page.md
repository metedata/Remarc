# Chrome Extension Instructions Page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a static instructions page hosted on R2 at `releases.remarc.app`, then link to it from the main site — same pattern as the app download.

**Architecture:** Self-contained HTML file with inline CSS, uploaded to the existing `remarc-releases` R2 bucket via `wrangler r2 object put`. No build step, no JS framework, no changes to the Cloudflare Pages deployment.

**Tech Stack:** HTML, CSS (inline), Wrangler CLI (R2 upload)

**Spec:** `docs/superpowers/specs/2026-03-20-chrome-extension-instructions-page-design.md`
**Approved mockup:** `.superpowers/brainstorm/39918-1774040198/page-layout-v8.html`

---

### Task 1: Find the extension zip URL on R2

**Files:** None (research only)

- [ ] **Step 1: Check what extension files exist on R2**

```bash
wrangler r2 object list remarc-releases --prefix="remarc-extension" 2>/dev/null || \
wrangler r2 object list remarc-releases --prefix="Remarc-Extension" 2>/dev/null || \
wrangler r2 object list remarc-releases
```

Or probe the public domain directly:

```bash
curl -I https://releases.remarc.app/remarc-extension.zip
curl -I https://releases.remarc.app/remarc-chrome-extension.zip
```

Note the working download URL for the extension zip.

- [ ] **Step 2: If extension zip is NOT on R2, upload it**

```bash
cd $REPO_ROOT
zip -r /tmp/remarc-extension.zip extension/
wrangler r2 object put remarc-releases/remarc-extension.zip --file=/tmp/remarc-extension.zip --content-type=application/zip
```

Verify:
```bash
curl -I https://releases.remarc.app/remarc-extension.zip
```

Expected: HTTP 200, content-type `application/zip`.

---

### Task 2: Create the instructions page HTML

**Files:**
- Create: `website/chrome-extension.html` (source file, lives in repo for version control)

- [ ] **Step 1: Create `website/chrome-extension.html`**

Build the full HTML page based on the approved mockup (`.superpowers/brainstorm/39918-1774040198/page-layout-v8.html`). Key differences from mockup to production:

1. **Use proper high-res Chrome SVG logo** — get the official Chrome logo SVG (search online for the correct paths), not the rough placeholder from the mockup
2. **Use the actual Remarc app icon** — reference `https://remarc.app/favicon.png` for the hero composite icon
3. **Set the download button `href`** to the R2 URL found in Task 1
4. **Add proper `<head>` meta tags:**
   - `<title>Chrome Extension — Remarc</title>`
   - `<meta name="description" content="Install the Remarc Chrome extension...">`
   - `<meta name="robots" content="noindex">` (utility page, not for search engines)
   - `<link rel="icon" type="image/png" href="https://remarc.app/favicon.png">`
   - `<meta name="theme-color" content="#0A0B14">`
5. **Ensure mobile responsiveness** — basic readability on small screens. The 640px max-width handles most of it; add a media query to reduce padding on narrow viewports.

Page structure (from spec):
- Hero: composite icon (Remarc app icon + Chrome badge at bottom-right), h1 title, subtitle, download CTA button, version meta
- Section "Installation": steps 1–5
- Divider
- Section "Connect to Remarc": steps 6–7
- Divider
- Section "Troubleshooting": 4 tip cards (disconnected, shortcuts, reconnect, port conflict)
- Footer with link to remarc.app

All CSS inline in `<style>` — no external stylesheets.

- [ ] **Step 2: Verify locally**

```bash
open website/chrome-extension.html
```

Check: dark background renders, noise texture visible, download button has correct href, all 7 steps visible, troubleshooting section visible, footer link works.

- [ ] **Step 3: Commit**

```bash
git add website/chrome-extension.html
git commit -m "feat: add chrome extension instructions page"
```

---

### Task 3: Upload to R2 and verify

- [ ] **Step 1: Verify Wrangler is installed and authenticated**

```bash
wrangler --version
wrangler whoami
```

If not installed: `npm install -g wrangler`
If not logged in: `wrangler login`

- [ ] **Step 2: Upload the HTML page to R2**

```bash
wrangler r2 object put remarc-releases/chrome-extension.html \
  --file=website/chrome-extension.html \
  --content-type=text/html
```

- [ ] **Step 3: Verify the page is live**

```bash
curl -I https://releases.remarc.app/chrome-extension.html
```

Expected: HTTP 200, content-type `text/html`.

```bash
open https://releases.remarc.app/chrome-extension.html
```

Verify: page loads correctly, styling intact, download button works.

---

### Task 4: End-to-end verification

- [ ] **Step 1: Test the full user flow in Chrome**

1. Open `https://releases.remarc.app/chrome-extension.html` in Chrome
2. Click "Download Extension" — verify zip downloads
3. Unzip the download
4. Go to `chrome://extensions`, enable Developer mode
5. Click "Load unpacked", select the unzipped folder
6. Pin the extension to the toolbar
7. Open Remarc app → Settings → Chrome Extension tab
8. Reload a browser tab — verify extension shows green connected dot

- [ ] **Step 2: Verify download link works independently**

```bash
curl -L -o /tmp/test-extension.zip "EXTENSION_ZIP_URL_FROM_TASK_1"
unzip -t /tmp/test-extension.zip
```

Verify the zip contains: `manifest.json`, `content.js`, `background.js`, `popup.html`, `popup.js`, `popup.css`, `main-world.js`, `icons/`.
