# Early Tester Invitation Landing Page - Design Spec

## Overview

A personalized landing page for early testers at `remarc.app/invite?name={Name}`. The page presents a cinematic envelope-opening ceremony that reveals a personal letter from Mete, followed by the early access content (video, download, feedback channels).

## User Flow

1. Tester receives URL like `remarc.app/invite?name=Mete`
2. Page loads with dark background. A slate-colored envelope fades in with their name embossed and an indigo wax seal.
3. After 2 seconds, the envelope auto-opens - flap folds back, seal breaks, letter peeks out.
4. The letter slides out and becomes the central element. It addresses the tester by name with a personal welcome from Mete.
5. Tester clicks "Accept Invitation". A circular stamp appears ("Invitation Accepted", R logo, their name) with a 3-second progress ring.
6. Main page slides up: video embed, download button, feedback section.
7. On revisit, the envelope is skipped (localStorage). A subtle "Replay invitation" link is available.
8. On mobile, the page shows a message asking to open on desktop.

## Visual Design

### Color Palette
- Background: `#0a0a0c`
- Envelope body: `#bfc5d2` (slate blue-gray)
- Envelope flap: `#ccd0da` (slightly lighter slate)
- Letter paper: `#d8dce6` (lighter slate, same family)
- Wax seal gradient: `#8185f7` to `#3730a3` (indigo)
- CTA / accent: `#6366F1` (Remarc primary indigo)

### Typography
- Name embossing: Georgia, italic, letter-spacing 3px
- Letter salutation: Georgia, italic
- Letter body: system-ui, 16px
- Letter signature: Georgia, italic
- Main page: system-ui throughout

### Textures
- Paper grain via CSS-only layered `radial-gradient` dots (no SVG filters)
- Envelope fold lines via subtle diagonal linear-gradients
- Seal inner ring detail for depth
- Stamp double-ring border for classic feel

### Natural Imperfections
- Wax seal rotated ~7deg
- Stamp rotated ~8deg
- Paper grain at varying dot sizes (3px, 5px, 7px layers)

## Letter Copy

```
Dear {name},

You've been invited to join a small group getting early access to Remarc.

I built this for people like us - builders who care about the details,
who won't ship until it feels right. Remarc is your feedback layer for
working with AI. I think you'll get it.

Your voice will shape what this becomes. I'm grateful you're here.

- Mete
```

If no `name` is provided in the URL, fall back to "Friend" (e.g., "Dear Friend,"). The letter reads naturally with this fallback.

## Animation Sequence

| Step | Duration | Easing | Properties |
|------|----------|--------|------------|
| Envelope fade in + scale | 0.8s | expo-out | opacity, transform: scale(0.95 to 1) |
| Pause | 2s | - | - |
| Flap fold (2D) | 0.6s | ease-out | transform: scaleY(1 to 0) |
| Seal break | 0.3s | ease-out | transform: scale(1.1), opacity: 0 |
| Letter peek | 0.4s delay + 0.8s | expo-out | transform: translateY |
| Letter expand to center | 0.6s | spring-like | transform, opacity |
| Envelope fade out | 0.4s | ease-out | opacity |
| Stamp appear | 0.5s | spring | transform: scale, border-radius |
| Progress ring fill | 3s | ease-in-out | stroke-dashoffset (SVG exception - performs fine on Safari, no layout/paint) |
| Transition to main | 0.8s | expo-out `(0.16, 1, 0.3, 1)` | transform: translateY(60px to 0), opacity |

All animations use `transform` and `opacity` for Safari compatibility, with `stroke-dashoffset` as the sole SVG exception (it animates on the compositor, not layout).

### `prefers-reduced-motion`
When `prefers-reduced-motion: reduce` is active, skip all animations and jump directly to the main content page (same as returning visitor behavior).

## Button States

The "Accept Invitation" CTA must have:
- **Default**: Indigo background (`#6366F1`), white text, rounded corners
- **Hover**: Slightly lighter indigo (`#818cf8`), subtle translateY(-1px) lift
- **Active/click**: Darker indigo (`#4f46e5`), translateY(0)
- **Focus-visible**: 2px indigo ring offset for keyboard navigation

The "Download for macOS" CTA follows the same pattern.

## Main Page Layout

1. "Remarc Early Access" - title
2. "Watch the video below to learn about Remarc." - subtitle
3. 16:9 video embed container (max-width ~800px, uses `aspect-ratio: 16/9`)
   - **Placeholder state**: Dark rounded container (`rgba(255,255,255,0.03)`) with subtle indigo border, centered play icon (circle + triangle), "Video coming soon" text below icon
   - **Video ready**: Replace placeholder div with YouTube iframe (`youtube-nocookie.com` for privacy, `loading="lazy"`)
4. "Download for macOS" - indigo CTA button -> `https://releases.remarc.app/Remarc-latest.zip`
5. "Requires macOS 14.4+" - tertiary text below download button
6. Feedback card: "Any feedback, ideas, or thoughts are welcome."
   - mete@metedata.com (mailto link)
   - @metedata on X (link to x.com/metedata)
   - @young.mete on Threads (link to threads.net/@young.mete)
7. "Replay invitation" - subtle tertiary-colored link at very bottom

## Security

- Name from URL is always injected via `textContent`, never `innerHTML`
- Name length capped at 50 characters (truncated silently)
- Parsed via `decodeURIComponent(new URLSearchParams(location.search).get('name'))`
- No user input is used in any HTML attribute or style context
- Fallback to "Friend" if name is empty, null, or only whitespace

## Mobile Strategy

- **Breakpoint**: `max-width: 768px` OR touch-capable device with narrow viewport
- **Check**: Once on page load (no resize listener needed - this is a one-time ceremony page)
- **Mobile view**: Remarc logo (R in indigo circle), tester's name, and message:
  > "This invitation is best experienced on desktop. Open this link on your Mac to continue."
  Plus a "Copy link" button so they can easily send it to their laptop.
- **iPad landscape**: Treated as desktop (viewport > 768px). iPad portrait gets mobile message.

## localStorage

- **Key `remarc-invite-accepted`**: Timestamp (ms) of when user clicked Accept. Presence means skip to main.
- **Key `remarc-invite-name`**: Cached name from URL, so revisits without `?name=` still personalize.
- **On load**: If `remarc-invite-accepted` exists, jump straight to main page (no animation, instant render).
- **"Replay invitation"**: Clears `remarc-invite-accepted`, resets all DOM states via `resetAllScenes()` helper, restarts FSM from envelope state.

## Meta Tags

```html
<meta name="robots" content="noindex, noarchive, nofollow">
<meta property="og:title" content="You're invited to Remarc Early Access">
<meta property="og:description" content="A personal invitation to shape the future of Remarc.">
<meta property="og:type" content="website">
<meta property="og:image" content="https://releases.remarc.app/icon_256x256.png">
```

## Technical Decisions

- **Single file**: `website/invite/index.html`, all CSS/JS inline
- **No framework**: Static HTML/CSS/JS matching existing site
- **Animation engine**: Web Animations API with async/await chaining (supported since Safari 13.1+, well within macOS 14.4+ target)
- **State management**: FSM via `body[data-state]` attribute
- **No 3D transforms**: 2D fold for flap to avoid Safari bugs
- **No SVG filters**: CSS dot-grid grain only
- **Semantic HTML**: `<main>`, `<article>`, `<header>` for screen readers
