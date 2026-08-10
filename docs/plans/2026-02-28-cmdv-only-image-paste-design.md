# CMD+V Only Image Paste

## Problem

The pasteboard polling timer in `InterceptingTextView` auto-captures any image that hits the clipboard while the comment box is open — screenshots, clipboard manager entries, images copied in other apps all get attached automatically.

## Solution

Remove the pasteboard polling timer entirely. The existing `paste(_ sender:)` override handles CMD+V correctly.

## Changes

### CommentTextEditor.swift — InterceptingTextView

Remove:
- Properties: `pasteboardTimer`, `lastKnownChangeCount`, `lastHandledChangeCount`, `suppressPasteboardWatch`
- Methods: `startPasteboardWatch()`, `stopPasteboardWatch()`
- `startPasteboardWatch()` call from `viewDidMoveToWindow()`
- De-duplication logic in `paste()` (no longer needed without the watcher)

Keep:
- `paste(_ sender:)` — the CMD+V handler, simplified to just check pasteboard for images
- `performKeyEquivalent` — routes CMD+V through `NSApp.sendAction`

### AttachmentStripView.swift

Remove `InterceptingTextView.suppressPasteboardWatch` toggling in the "Copy Image" context menu action.

## Behavior After Change

| Scenario | Result |
|----------|--------|
| CMD+V with image on clipboard | Attaches immediately |
| Raycast clipboard history selection | Does NOT attach (paste goes to frontmost app) |
| Screenshot while comment box is open | Does NOT attach (no polling timer) |
| Paperclip button (file picker) | Still works (unchanged) |
