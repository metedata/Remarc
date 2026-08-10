---
name: sync-html-design-system
description: >
  Use when the user changes a UI element in Remarc's macOS app (icon,
  badge, type label, component variant) and asks to reflect, mirror,
  encode, or sync it in the HTML design system — typically phrased as
  "add this to the design system", "mirror in HTML", "encode this on
  the web version", or "make sure the design system is up to date".
  Also triggers when the user asks to "export" a new icon, asset, or
  symbol into the HTML/landing-page mockups.
---

# Sync HTML Design System

The `website/design-system-poc/` directory is the HTML mirror of Remarc's
macOS UI. When the Swift app changes a visible UI element, the HTML
version usually needs the matching change. This skill captures the file
layout, the icon system's two-CSS-files quirk, and the sync map.

## File Inventory

```
website/design-system-poc/
  index.html           Static gallery — every UI state has a literal example
  app.js               Renders dynamic examples from cardTypes / writingModes / editorModes arrays
  styles.css           Full stylesheet incl. .icon.<alias> rules using ./assets paths
  sf-symbol-data.css   Parallel .icon.<alias> rules using inline data: URIs (for file:// captures)
  assets/
    sf-symbols/<sf-name>.svg   Verbatim SF symbol filenames (e.g. chevron.left.forwardslash.chevron.right.svg)
    <other>.svg                Custom assets (logos, fixtures)
```

## SF Symbol Icon — Pattern

Two changes per icon:

1. Drop the SVG at `assets/sf-symbols/<sf-symbol-name>.svg` (keep the
   literal SF symbol filename, dots and all). If the SVG isn't already
   exported, run the pipeline in `.worktrees/export-sf-symbol-assets/scripts/`.
2. Add a rule in **both** CSS files:
   - `styles.css`: `.icon.<alias> { --symbol: url("./assets/sf-symbols/<sf-name>.svg"); }`
   - `sf-symbol-data.css`: same rule but with the inline `data:image/svg+xml,…` URI

`<alias>` is the friendly handle used in HTML (`.icon.globe`, `.icon.web-code`).
Both CSS files exist because `file://` captures can't load external SVGs
reliably — the inline-data version is what fixture screenshots use.

The `.icon` class is alpha-mask + `currentColor`, so the SVG renders as
the text color. Gradient or multi-color assets do NOT work here.

## Gradient / Color-Preserving Asset — Pattern

Use `background-image` instead of mask so colors are preserved:

```css
.<asset-class> {
  width: 14px; height: 14px;
  display: inline-block;
  flex: 0 0 auto;
  background-image: url("./assets/<file>.svg");
  background-size: contain;
  background-repeat: no-repeat;
  background-position: center;
}
```

Example: `.hyperframes-logo` for the HF logo's cyan→green gradient.

## Badge — Pattern

Type icons and badges are different concepts:

- **Type icon**: identifies the comment's kind. Rendered via `.icon.<alias>`
  in `.card-title` / `.comment-input-type-label`.
- **Badge**: indicates extra metadata is attached. Rendered as a pill
  next to the type icon.

Existing badges:

| Class | Tint | Meaning |
|---|---|---|
| `.web-badge` | `--primary` 14% | Web context attached (selector, DOM, computed styles) |
| `.hf-badge`  | `--accent`  14% | HyperFrames composition context attached |

When adding a new context kind, mirror the `.web-badge` rule (rounded
4px, padding 2px 6px, 14% tinted background) and wire it into the
`app.js` card renderer plus the static `index.html` example.

## Sync Map

| Remarc Swift change | HTML design-system change |
|---|---|
| `CommentType.iconName` returns a new SF symbol | `app.js` `cardTypes.icon` + `writingModes.icon` + `editorModes.icon` + static `index.html` `.card-title .icon.<alias>` |
| New SF symbol used anywhere | Add SVG to `assets/sf-symbols/` + add `.icon.<alias>` rule in **both** `styles.css` AND `sf-symbol-data.css` |
| New context badge alongside `WebContextBadge` | Define `.<kind>-badge` CSS + render it in `app.js` (search `card.badge` for the pattern) + add to `index.html` example |
| New `CommentType` case | Add a `cardTypes` entry + a `writingModes` entry + an `editorModes` entry in `app.js` |
| New custom asset with its own colors (logos, gradients) | Add SVG to `assets/` + add `.<asset-class>` rule using `background-image` (not mask) |

## Verification

```bash
cd website/design-system-poc
python3 -m http.server 5050 --bind 127.0.0.1
open http://127.0.0.1:5050/index.html
```

Visually confirm the new element matches the macOS app's screenshot of
the corresponding state. The Web Element card near the top of the
gallery is the canonical place to check icon/badge wiring.

## Common Mistakes

- Editing `styles.css` but not `sf-symbol-data.css` — file:// captures
  silently render no icon
- Putting a gradient or multi-color SVG into the `.icon` system — it
  renders as solid currentColor (mask discards color info)
- Switching the **badge** icon when only the **type** icon should change
  (or vice versa) — they're different roles
- Updating the static `index.html` example but not the `app.js`
  renderer (or vice versa) — the dynamic gallery diverges from the
  static one
- Adding a new SF symbol but forgetting to copy the SVG into
  `assets/sf-symbols/` — the CSS rule loads a 404
