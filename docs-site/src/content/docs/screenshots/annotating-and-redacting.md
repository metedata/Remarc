---
title: Annotate & redact
description: Draw arrows, shapes, text, and counters on Remarc screenshots, redact sensitive content with blur or pixelate, and edit marks later.
---

Remarc's annotation canvas draws on captured screenshots: arrows, shapes, freehand strokes, text, numbered counters, and two redaction tools.

## Open the canvas

During capture, click the Annotate pill next to the selected region (or press `Shift+Cmd+A`). The region locks while you annotate. Click Done or press `Escape` to return to the comment, then save; your marks are saved with the screenshot.

After capture, click the screenshot thumbnail on a comment card to open the [preview panel](/screenshots/capturing/), then click Annotate.

## Tools

Each tool has a single-key shortcut:

| Tool | Key | What it does |
| --- | --- | --- |
| Select | `V` | Move or edit an existing mark |
| Arrow | `A` | Four styles: straight, curved, double-headed, dashed |
| Rectangle | `R` | Outlined rectangle |
| Oval | `O` | Outlined oval |
| Line | `L` | Straight line |
| Pen | `P` | Freehand drawing |
| Highlighter | `H` | Translucent stroke that keeps the content underneath readable |
| Text | `T` | Text label |
| Counter | `C` | Numbered badge; the number increases with each one you place |
| Blur | `B` | Blur a region |
| Pixelate | `X` | Pixelate a region |

The toolbar also has a six-color palette (red, amber, green, blue, black, white), three stroke widths (Thin, Medium, Thick), zoom controls with a zoom level indicator, Undo (`Cmd+Z`), and Redo (`Shift+Cmd+Z`).

## Redact sensitive content

Blur and pixelate recompute every pixel in the region as an average of its neighborhood, so no original pixel value survives in the output. Pixelate never samples original pixels into its cells.

:::caution
Redaction makes content unreadable, but it is not a cryptographic guarantee. Very low-entropy content, such as a short PIN, could in principle be narrowed down by someone who knows the possible values.
:::

## Edit marks later

Marks stay editable after capture, including marks you drew during capture. Reopen the canvas from the preview panel to move, restyle, or delete them; the saved screenshot file always shows the annotations.

While you have unsaved marks in the preview, the header shows two buttons: **Apply** composites the annotations into the saved image, and **Discard** throws away the unsaved changes.

Applied redactions are permanent. Blur and pixelate regions cannot be removed once the screenshot is saved, and any marks drawn before the last redaction are flattened with them. Marks drawn after the last redaction come back editable the next time you annotate.

The trash button in the toolbar clears every mark, after a "Discard all annotations?" confirmation.
