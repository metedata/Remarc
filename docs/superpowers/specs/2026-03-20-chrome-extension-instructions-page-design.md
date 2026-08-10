# Chrome Extension Instructions Page — Design Spec

## Overview

A standalone page at `remarc.app/chrome-extension` that guides users through installing and connecting the Remarc Chrome extension (sideloaded via developer mode, not Chrome Web Store).

## URL & Routing

- **Path:** `/chrome-extension`
- **Deployment:** Cloudflare Workers via Wrangler CLI (separate from the existing Cloudflare Pages site)
- **Domain:** `remarc.app` (route the `/chrome-extension` path to the Worker)

## Design

### Visual Style
- **Dark mode** — deep navy background (`#0A0B14`), matching remarc.app aesthetic
- **Indigo/violet palette** — `#6366F1`, `#818cf8`, `#a5b4fc` for accents, numbers, code, links
- **Subtle top glow** — single radial gradient from top center, fading into background (not scattered blobs)
- **Noise texture** — fractal noise overlay at low opacity (~0.1), mix-blend-mode overlay
- **No header/nav bar** — page starts directly with the hero

### Layout
- Single-scroll page, max-width `640px`, centered
- Three sections separated by subtle dividers

### Mockup Reference
- Final approved mockup: `.superpowers/brainstorm/39918-1774040198/page-layout-v8.html`

## Page Structure

### 1. Hero
- **Composite icon:** Remarc app icon (high-res, from `assets/`) with Chrome logo badge overlaid at bottom-right corner
  - App icon: 72x72px, 18px border-radius, drop shadow
  - Chrome badge: 30px circle, positioned absolute bottom-right with -6px offset
  - Use proper high-res Chrome SVG logo (not the placeholder from mockup)
- **Title:** "Install the Chrome Extension"
- **Subtitle:** "The Remarc extension captures web context — element data, styles, and structure — when you comment on web pages."
- **Download CTA:** Indigo gradient button with download icon, links to R2-hosted extension zip
- **Meta line:** Version number + Chrome requirement (e.g., "v0.1.0 · Requires Chrome 120+")

### 2. Installation Steps (1–5)
Section label: "INSTALLATION"

1. **Unzip the download** — Extract zip, keep folder in a permanent location (Chrome needs it to stay)
2. **Open Chrome Extensions** — Navigate to `chrome://extensions`
3. **Enable Developer Mode** — Toggle switch in top-right corner (screenshot placeholder)
4. **Load the extension** — Click "Load unpacked", select the unzipped folder
5. **Pin it to your toolbar** — Puzzle piece icon → pin "Remarc Web Context"

### 3. Connect to Remarc Steps (6–7)
Section label: "CONNECT TO REMARC"

6. **Enable in Remarc settings** — Open Remarc app → Settings → Chrome Extension tab (starts the WebSocket server on port 9274). Green status dot confirms it's running.
7. **Reload your browser tab** — Refresh any Chrome tab. Extension icon shows green dot when connected.

### 4. Troubleshooting
Section label: "TROUBLESHOOTING"

Four tip cards with icon + title + description:

- **Extension shows "Disconnected"** — Remarc app must be running; Chrome Extension settings tab must have been opened at least once; reload the page
- **Keyboard shortcuts not working** — Chrome blocks `⌘` shortcuts in extensions; must use `⌃⇧` (Ctrl+Shift) or `⌥⇧` (Alt+Shift); configurable in Remarc Settings → Chrome Extension
- **Connection drops after restarting Remarc** — Extension auto-reconnects every 3 seconds; reload tab if needed
- **Port conflict on 9274** — Another app may be using the port; check Remarc Chrome Extension settings for "Port unavailable" error

### 5. Footer
- Link to `remarc.app`
- Copyright: "© 2026 Metedata"

## Technical Details

### Extension Connection
- WebSocket on `127.0.0.1:9274` (localhost only)
- Server starts lazily when user opens Chrome Extension tab in Remarc Settings
- Extension content script auto-retries connection every 3 seconds
- Single active connection at a time (new connection replaces old)

### Extension Info
- Name: "Remarc Web Context"
- Manifest V3
- Current version: 0.1.0
- Download hosted on R2 (existing setup)

## Deployment Approach

Use Wrangler CLI to create a Cloudflare Worker that:
1. Serves the static HTML page at `/chrome-extension`
2. Returns proper headers (cache, security)
3. Routes via `remarc.app/chrome-extension`

This keeps it decoupled from the existing Cloudflare Pages deployment for the main landing page.

## Out of Scope
- Screenshots in steps (can be added later)
- Chrome Web Store listing
- Analytics/tracking
- Mobile responsiveness beyond basic readability
