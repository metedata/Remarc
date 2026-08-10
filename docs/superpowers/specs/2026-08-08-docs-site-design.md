# Remarc Documentation Site — Design

**Date:** 2026-08-08
**Status:** Approved (framework, URL, and scope confirmed by Mete)

## Goal

Ship end-user product documentation for Remarc's release without designing a docs site from the ground up. Guides, how-tos, and troubleshooting — not API reference docs.

## Decisions (approved)

| Decision | Choice | Why |
|---|---|---|
| Framework | **Astro Starlight** (latest 0.4x, MIT) | Best intersection of "looks shipped with zero design work" and "fits existing infra": dark/light mode, zero-config Pagefind search, mobile nav, landing hero — all built in. Static output, official Cloudflare Pages guide, maintained by the Astro org. Verified against npm/GitHub/Cloudflare primary sources 2026-08-08. |
| URL | **docs.remarc.app** — its own small Cloudflare Pages project | Cloudflare Pages can't split one domain across two projects by path; a subdomain avoids a Worker proxy or merged-deploy script. Also sidesteps Starlight's base-path wart (Astro doesn't auto-prepend `base` to markdown links: Starlight discussions #966/#1407/#3660) and gives docs an independent deploy cadence. Matches manual.raycast.com, docs.proxyman.com, docs.granola.ai. |
| Scope | **Full outline, ~25 pages** | Complete user-facing coverage at release (outline below). |

Alternatives considered: VitePress (smoothest subpath support but plainer theme, stable branch 12 months old with 2.0 in long alpha), Mintlify (best zero-effort polish, chosen by Superwhisper/Granola, but hosted on their infra with platform/pricing risk; static export is Enterprise-only private beta), Docusaurus (no built-in search, dated theme, heaviest stack), MkDocs Material (its own team put it in maintenance mode Nov 2025 in favor of Zensical). Fumadocs/Nextra eliminated on verification (OpenNext-on-Cloudflare default; 8-month release gap, single maintainer).

## Architecture

- New top-level directory `docs-site/` in the app repo (`docs/` is taken by internal docs). Standard Starlight project: `npm create astro` with the Starlight template, content in `docs-site/src/content/docs/` as plain Markdown/MDX.
- Pure static build (`astro build` → `dist/`), no adapter, no server runtime.
- Deployment: separate Cloudflare Pages project (`remarc-docs`), custom domain `docs.remarc.app`. Build command `npm run build`, output `dist/`, root directory `docs-site`. Going live needs one DNS record + Pages project creation — a release-time step, documented in the site README, not automated here.
- Search: built-in Pagefind (client-side, ships in the build output; no config, works on static hosting).

## Design/branding

Skin the default Starlight theme with the Remarc brand kit (docs/brand-kit.md) via CSS custom properties only — no custom components at v1:

- Accent: Soft Indigo `#6366F1` (light) / `#A5B4FC` (dark), matching `remarcPrimary`.
- Dark-first presentation to match the Raycast-style app aesthetic; both themes supported.
- Landing page: Starlight splash layout with hero + link cards (built-in components).
- Copy rule: no em dashes anywhere in the docs (user-facing text). Use hyphens.

## Content plan (~25 pages)

Sourced from a code-verified feature inventory (2026-08-08). Every page's claims (hotkey defaults, setting names, permission behavior) trace to source files, not memory.

1. Getting Started: What is Remarc / Installation & Onboarding / Permissions Explained
2. Basics: Menu Bar & Popover / Commenting on Text Selections / Quick Notes / Sessions & the Inbox / Comment Statuses & History
3. Screenshots: Capturing Screenshot Comments / Annotating & Redacting
4. Voice (macOS 26+): Dictation / Voice Comments & Crit Mode / Transcription Engines & Models
5. Exporting: Copying & Exporting Comments
6. Chrome Extension: Setup & Capturing Web Elements
7. Agent Integrations: Overview / Claude Code / Codex & Cursor / Claude Desktop & Other MCP Clients / MCP Tools Reference
8. Automation: Webhooks
9. Reference: Keyboard Shortcuts / Settings Reference / Data Storage, Privacy & Updates / Troubleshooting & FAQ

Content emphasis follows what works for menu-bar utilities (verified across 15 comparable apps): permissions and troubleshooting get first-class treatment; screenshots moderate (roughly one per feature page, added post-v1 as needed); nav depth max 2 levels.

## Error handling / risks

- Starlight is pre-1.0: pin the minor version; upgrades are config-only at this site size.
- macOS 26-gated features (Voice section) must say so explicitly to avoid support noise from older-macOS users.
- Screenshots deferred where not yet captured — pages must read complete without them.

## Testing

- `astro build` must pass clean (broken internal links fail the build via Starlight's link validation once `starlight-links-validator` is added — include it).
- Manual preview pass of every page in light + dark.
- Content accuracy verified against app source in a review pass before merge.
