# Main landing page design

Date: 2026-08-08
Status: approved (design approved in session; this doc is the written spec)

Convert the early tester invite page into the public Remarc landing page for the open-source release.

## Summary

A new `website/index.html` replaces the current "Coming Soon" placeholder at remarc.app. It is derived from `website/invite/index.html` (single self-contained HTML file, inline CSS/JS, no build step), keeping the visual identity — background stack, colors, typography, FAQ accordion — while stripping the invitation ceremony entirely. The invite page itself stays untouched at `/invite` so existing tester links keep working.

Approved decisions:

- Title: **Remarc** (was "Remarc Early Access")
- Subtitle: **"The feedback layer between you and your coding agent."**
- Video: self-hosted launch video (native `<video>`, not YouTube)
- CTAs: equal-size Download + GitHub buttons; star count chip auto-hidden below threshold
- Docs link: FAQ answer + footer only (no nav, no link under CTAs)
- Mobile: full responsive page (the mobile gate is removed)
- No intro animation, no replay button - land straight in the final state
- Icon: larger than today, with the Relinq tilt+shine hover effect
- Analytics: **out of scope** (user did not opt in; can be added later)

## Source material

| What | Where |
|---|---|
| Page being adapted | `website/invite/index.html` (1818 lines) |
| Page being replaced | `website/index.html` ("Coming Soon" placeholder) |
| Tilt+shine effect | `/Users/mete/Developer/CaAML/website/styles.css` lines 156-197, `script.js` lines 1-59, markup `index.html` 179-182 |
| Launch video | `/Users/mete/Developer/remarc-hero-animation/renders/2026-08-06-soundtrack-1920.mp4` (45.5s, 1920x1200 = 16:10, h264+aac soundtrack, 14 MB) |
| Head/JSON-LD model | `/Users/mete/Developer/CaAML/website/index.html` (SoftwareApplication + FAQPage JSON-LD) |
| Copy sources | `Metedata-Obsidian-Vault/metedata-ventures/remarc/product-marketing-context.md` (objections table; note stale pricing/hooks claims), `landing-page-structure.md` |

## What is deleted from the invite page

- `#scene-envelope`, `#scene-reveal`, `#scene-mobile` markup and all their CSS
- Ceremony SVG defs (`#paper-grain`, `#stamp-emboss`, `#stamp-worn`, lines 777-822) and reveal-scene defs (920-969). **Keep** `#page-grain-filter` (line 834) - the background grain uses it.
- The ceremony state machine and JS: `runCeremony`, `transitionToMain`, hold-button logic, name parsing (`?name=`, localStorage `remarc-invite-name`), `remarc-invite-accepted` gate, `?debug` / `?flap=2d` params, replay handler
- Replay button (`#replay-link`) and its `body[data-state]` CSS
- Mobile gate logic and `mobile-copy-btn`
- Dead CSS: `.play-icon` / `.video-placeholder-text` placeholder styles (invite 538-548)
- `<meta name="robots" content="noindex, noarchive, nofollow">`
- Early-tester FAQ items: "How should I test it?", "What kind of feedback are you looking for?", "Can I post about it?"

## What is kept unchanged

- Background stack, verbatim: `.nebula-container` + 3 orbs, `.page-glow`, `.page-vignette`, `.halo-anchor > .rotating-halo`, `#dust-canvas` + particle script (100 desktop / 40 mobile), `.page-grain`. These are already decoupled from the ceremony; their existing fade-ins (0.5s/1s/1.5s delays) count as ambient polish, not an intro animation.
- FAQ accordion markup pattern and the WAAPI height-animation script (invite 1735-1769)
- Color tokens, fonts, dividers, `.video-wrap` frame styling (aspect ratio changes, below)
- Feedback section: heading, copy, email / X / Threads icon links, verbatim
- Download CTA visual style (indigo pill, Apple logo SVG, hover/active/focus states, "Requires macOS 14.0 or later" caption)

## New page structure

1. Background layers (unchanged)
2. Hero: icon → title → subtitle
3. Video
4. CTA row + caption
5. Divider, feedback section, divider
6. FAQ
7. Footer (new)

### Hero

- Icon: `https://releases.remarc.app/icon_256x256.png` (existing asset, 256px source is enough for 96px @2x), **96px desktop / 80px mobile**, border-radius 19px / 16px (Relinq's 160:31 ratio applied). Add `<link rel="preload">` for it.
- Relinq tilt+shine ported as-is with sizes adapted: wrapper with `perspective: 1000px` + `drop-shadow(0 12px 24px rgba(0,0,0,0.4))`, shine overlay div with radial-gradient (white 0.06 → 0.02 → transparent) at `--shine-x`/`--shine-y`, shine circle radius scaled ~120px → 72px. JS: max tilt 8°, `scale3d(1.02)`, 0.15s ease-out transforms, `.tilt-active` opacity fade 0.2s, `(hover: none)` disables everything on touch.
- `<h1 class="main-title">Remarc</h1>`
- Subtitle: `The feedback layer between you and your coding agent.`
- Entrance: keep the existing subtle stagger (items fade/translate in at 300 + i*120ms, as `skipToMain()` does today). Under `prefers-reduced-motion`, skip the stagger and show content immediately.

### Video

- Native `<video controls playsinline preload="metadata" poster="...">`, no autoplay (the video has a soundtrack; autoplay would either be muted-pointless or hostile).
- Frame: existing `.video-wrap` dark rounded style, aspect ratio corrected 16/9 → **16/10**.
- Hosting: upload to the existing R2 bucket (`remarc-releases`, served at `releases.remarc.app`):
  - `https://releases.remarc.app/media/remarc-launch.mp4` (the 2026-08-06-soundtrack-1920 render, uploaded unmodified)
  - `https://releases.remarc.app/media/remarc-launch-poster.jpg` (frame extracted with ffmpeg; pick a clean, representative frame - the implementer chooses by eye, e.g. the product-name resolve near the end)
- Rationale for R2 over committing to the repo: the repo is about to be open-sourced through a media-purged mirror; a 14 MB mp4 in `website/` fights that. R2 is already the binary-hosting pattern.
- Upload mechanics: try `wrangler r2 object put` locally; if no local credentials exist, hand Mete the exact commands as a manual step before deploy.

### CTA row

Two buttons, identical width and pill geometry, side by side on desktop, stacked full-width on mobile. Implementation: a flex/grid row where both buttons share a fixed min-width (desktop) / 100% width (mobile).

- **Primary - Download for macOS**: existing `.cta-download` indigo style + Apple logo SVG → `/download` (existing 302 to the current zip; the release workflow keeps it current). Caption below the row: "Requires macOS 14.0 or later".
- **Secondary - GitHub**: same dimensions, ghost variant (transparent bg, 1px indigo-tinted border, text/icon in the page's secondary text color; hover raises border+bg slightly, active presses). GitHub mark SVG (official octocat path, `currentColor`) → `https://github.com/metedata/Remarc`.
- **Star chip** inside the GitHub button: a `<span data-stars hidden>` after the label.
  - Client JS: fetch `https://api.github.com/repos/metedata/Remarc` (`Accept: application/vnd.github+json`), read `stargazers_count`.
  - Cache in localStorage (`gh-stars:metedata/Remarc`) with 1-hour TTL; stale-if-error.
  - Reveal the chip only when count ≥ **25**. Below threshold, on fetch failure, or with JS disabled, the button reads just "GitHub". Never show 0, spinners, or placeholders; reserve no layout space (chip is `hidden` until populated - no layout shift).
  - Format with `Intl.NumberFormat('en', {notation:'compact', maximumFractionDigits:1})` ("1.2K"). Full number goes in the link's `aria-label` ("Remarc on GitHub, 1,234 stars").
- Both buttons: distinct hover AND active states (house rule: every CTA has hover and click states).

### FAQ

Keep `<details>`/`<summary>` accordion + animation. Final set, in order:

1. **What is Remarc?** - refreshed answer: menu bar app, point at anything on screen (text, screenshots, web elements, voice), comments carry context, agents read and resolve them over MCP.
2. **How much does Remarc cost?** - free and open source (MIT). No accounts, no subscriptions.
3. **Which coding agents does it work with?** - Claude Code and Codex via the plugin marketplace, Cursor via the built-in integration, and anything else that speaks MCP.
4. **Why not just type everything into my agent's chat?** - adapted from the objections table: "It's the difference between writing a bug report and pointing at the bug." Selected text, source app, selectors, and your commentary travel with the comment.
5. **Is my data private?** - everything stays on your Mac in a local file; no telemetry, no accounts, nothing leaves the machine.
6. **How do I get the Chrome extension?** - keep the existing answer + `/chrome-extension` link; verify the "not on the Chrome Web Store yet" claim is still accurate at implementation time and update if not.
7. **Where can I learn more?** - link to `/docs` (documentation page; see dependency below).
8. **How do I provide feedback?** - GitHub issues first, plus the email / X / Threads contacts from the feedback section.

Copy rules: all answers written fresh or checked at implementation time; hyphens only, never em dashes; confident, developer-native tone; avoid "annotation tool" / "productivity app" vocabulary.

### Footer (new)

Single quiet line, matching the page's muted text styles:

`Documentation · GitHub · Contact · © 2026 Metedata`

- Documentation → `/docs`
- GitHub → `https://github.com/metedata/Remarc`
- Contact → `mailto:mete@metedata.com`

### Head / meta

- `<title>Remarc - The feedback layer between you and your coding agent</title>`
- `<meta name="description" content="Remarc is the feedback layer between you and your coding agent. Point at anything on your Mac - text, screenshots, web elements, voice - and your agent reads and resolves your comments over MCP. Free and open source.">`
- `<link rel="canonical" href="https://remarc.app/">`
- OG + Twitter card tags (og:title "Remarc", og:description = subtitle, og:url, og:image = `https://releases.remarc.app/icon_256x256.png` for now - a proper og-image is a later, separate task)
- `<meta name="robots" content="index, follow">`
- JSON-LD `SoftwareApplication` (operatingSystem "macOS 14.0+", price 0/USD, downloadUrl `https://remarc.app/download`, author Metedata) and `FAQPage` mirroring the 8 FAQ items - modeled on the Relinq page.
- Keep theme-color, favicons.

### Responsive behavior

- The mobile gate is gone; all content renders on all viewports.
- ≤768px (the invite page's existing breakpoint): icon 80px, title/subtitle scale down, CTA buttons stack full-width, video full-width, FAQ/feedback paddings tighten.
- Tilt+shine disabled on touch via `(hover: none)` check (JS returns early; shine div stays inert).
- Dust canvas already drops to 40 particles on mobile.

## Out of scope

- Analytics (not opted in; Cloudflare Web Analytics is a one-tag add later if wanted)
- The documentation page itself (only links to `/docs` are in scope)
- A designed og-image
- Any changes to `website/invite/`, `/download` redirect mechanics, or the release pipeline

## Dependencies / launch coordination

- **GitHub repo visibility**: `metedata/Remarc` is private today (0 stars). The GitHub button and footer link 404 until it flips public. Deploy this page together with (or after) the repo going public. The star fetch fails silently by design, so a private repo never breaks the page visually.
- **`/docs` page**: does not exist yet (404 today). The FAQ + footer links ship pointing at `/docs`; the docs page is a separate effort that should land before or with this page. If it slips, the links 404 - flag at deploy time.
- **Video upload**: the two R2 objects must exist before merge-to-main deploys the page (Cloudflare Pages auto-deploys from main).

## Testing

- Serve `website/` locally (static server + Browser pane): verify desktop and mobile viewports, hover tilt+shine on desktop, no tilt on touch emulation, FAQ accordion, video poster + click-to-play with sound, both CTAs' hover/active states.
- Star chip: temporarily point the fetch at a high-star public repo to verify formatting, threshold logic, and aria-label; verify silent failure with network blocked; then point back at `metedata/Remarc`.
- `prefers-reduced-motion`: content appears without stagger; page remains fully usable.
- JS disabled: both CTAs and all links work (plain anchors); star chip and tilt simply absent.
- Validate JSON-LD (schema.org validator) and check no `noindex` remains.
- Confirm `/download` still resolves to the current release zip.

## Implementation notes

- Work happens in a git worktree per repo policy: `git worktree add .worktrees/main-landing-page -b feat/main-landing-page`.
- Single-file page: all CSS/JS stays inline in `website/index.html`, matching the invite page's convention.
- Expected size: roughly half the invite page (~900 lines) after ceremony deletion.
