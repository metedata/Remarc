# Dynamic Comment Input — Implementation Report

## What Was Accomplished (Working)

### 1. Dynamic text editor height
The comment input box now grows as the user types, up to a 300pt max height, then becomes scrollable. Uses `sizeThatFits(_:nsView:context:)` on the `NSViewRepresentable` with `NSLayoutManager.usedRect(for:)` to calculate content height. The key fix for scrolling was making `sizeThatFits` respect `proposal.height` so the `NSScrollView` is correctly constrained.

### 2. Grow upward (anchor bottom edge)
The panel grows upward so the cursor stays in place. In `CommentInputWindowController.updatePanelHeight()`, AppKit origin.y is kept fixed, which anchors the bottom edge in AppKit's bottom-left coordinate system.

### 3. Asymmetric panel animation
Growing is instant (no text clipping), shrinking uses a 0.15s ease-out `NSAnimationContext` animation.

### 4. Cmd+Enter to save
Changed from plain Enter to Cmd+Enter for submit. Added `"\r"` case in `performKeyEquivalent` to handle Cmd+Enter in the nonactivatingPanel context. Save button shows "Save ⌘↵" with dimmer shortcut hint.

### 5. Conditional dividers
Divider lines between header/editor/footer only appear when content is scrollable. Uses `onContentHeightChange` callback from `CommentTextEditor` to track whether content exceeds `textMaxHeight`.

### 6. VStack(spacing: 0) layout
Restructured from `VStack(spacing: 8)` to `VStack(spacing: 0)` with section-specific padding, matching the popover content pattern.

### 7. Editor reference text
`CommentEditorView` reference text lineLimit increased from 3 to 10. Footer updated to match new "Save ⌘↵" button style.

---

## Unsolved Issues

### Issue 1: Overlay scroller flash during growth

**Problem**: When `hasVerticalScroller = true` with overlay style, the scroller briefly flashes every time the text editor's content height changes (during growth), even before content is scrollable.

**Root cause**: `reflectScrolledClipView(_:)` is called automatically when the document view's frame changes. This updates scroller values internally, which triggers the overlay scroller's CALayer fade-in animation. This is a **separate code path** from `flashScrollers()`.

**What was tried**:

| Approach | Result |
|----------|--------|
| `hasVerticalScroller = false` | No flash, but no scrollbar when content overflows |
| Toggle `hasVerticalScroller` in `sizeThatFits` | Toggling on triggers a flash |
| Subclass NSScrollView, override `flashScrollers()` only | Flash persists — different code path (`reflectScrolledClipView`) |
| Override `flashScrollers()` + `tile()` with `verticalScroller?.isHidden = true` | Flash gone, but scrollbar never appears even when scrollable (`isHidden` is persistent) |
| Override `reflectScrolledClipView` to suppress when not overflowing | Scrollbar doesn't track position during actual scrolling (broke scroll) |
| Override `reflectScrolledClipView` + hide scroller alpha after super | Scrollbar disappears entirely |

**Current state**: `hasVerticalScroller = false` — no flash, but no scrollbar when content overflows. User can still scroll with trackpad, just no visual indicator.

**Recommended next steps**:
- Try subclassing `NSScroller` itself to control visibility at the scroller layer level (override `drawKnob`, control `alphaValue`)
- Try wrapping document view frame changes in `CATransaction.setDisableActions(true)` to suppress implicit animations
- Investigate the private `NSScrollerImp` infrastructure that manages overlay scroller animations
- Look at how [ChimeHQ ScrollViewPlus](https://github.com/ChimeHQ/ScrollViewPlus) handles overlay scroller visibility
- Consider using legacy (non-overlay) scroller style which doesn't have flash behavior, combined with `autohidesScrollers = true`
- Consider enabling the scroller with a delay only AFTER the editor reaches max height and stops growing

### Issue 2: Indigo left border bar doesn't extend to the Divider

**Problem**: The 2pt indigo bar on the quote text reference stops at the Text element's bottom edge. There's an 8pt gap (from `.padding(.bottom, 8)`) between the bar's end and the Divider line.

**Root cause**: The `.overlay(alignment: .leading)` is on the inner `Text` element. The overlay's frame exactly matches the Text's frame. The padding between the Text and the Divider is outside the overlay's frame.

**What was tried**:

| Approach | Result |
|----------|--------|
| `.padding(.bottom, -8)` on the overlay bar | Bar didn't visibly extend — unclear why (research says SwiftUI doesn't clip overlays by default) |
| Move overlay to outer header VStack with `.topLeading` alignment + padding offsets | Bar still didn't extend to divider — same visual result |
| `GeometryReader` inside overlay with explicit offset and height calculation | Bar still didn't extend to divider — same visual result |
| HStack with bar as sibling view | Shape expanded to unbounded height, header became too tall |

**Current state**: Overlay on inner Text, bar matches text height only. Gap between bar and divider persists.

**Why approaches failed**: Despite multiple theoretically-correct implementations confirmed by research, the bar never extended to the divider. Possible explanations:
1. SPM build cache may not have picked up all changes despite `xcodebuild clean` (known issue in this project — incremental builds don't always recompile SPM package changes)
2. The `GeometryReader` with `.offset()` moves rendering but the parent may still clip at some level
3. Some clipping in the view hierarchy not detected by grep — possibly at the AppKit hosting level (NSHostingView/NSPanel content view)
4. Multiple attempts may have interfered with each other if build cache wasn't fully invalidated

**Recommended next steps**:
- Add a visible debug background (e.g., `Color.red.opacity(0.3)`) to the overlay to verify where it actually renders at runtime
- Try drawing the border in AppKit (CALayer sublayer on the NSPanel's content view) instead of SwiftUI overlay
- Try `drawingGroup()` or `compositingGroup()` to change how the overlay renders
- Consider a different visual approach: inset the Divider by 16pt with `.padding(.horizontal, 16)` so it aligns with the content area rather than going edge-to-edge — this sidesteps the extension problem entirely
- Delete DerivedData entirely (`rm -rf ~/Library/Developer/Xcode/DerivedData/Remarc-*`) before testing to guarantee no cached objects

---

## Files Modified

- **CommentTextEditor.swift** — `sizeThatFits`, `onContentHeightChange` callback, `textContentHeight` computed property, `resize(withOldSuperviewSize:)`, Cmd+Enter in `performKeyEquivalent`
- **CommentInputView.swift** — `VStack(spacing: 0)` layout, conditional dividers, "Save ⌘↵" button, `headerSection` extracted as computed property
- **CommentEditorView.swift** — lineLimit 10, "Save ⌘↵" button
- **CommentInputWindowController.swift** — `maxPanelHeight` 460, `updatePanelHeight()` with asymmetric animation, `ceil()` rounding, deferred initial measurement

## Research Sources

- [Apple: reflectScrolledClipView](https://developer.apple.com/documentation/appkit/nsscrollview/reflectscrolledclipview(_:))
- [Apple: flashScrollers](https://developer.apple.com/documentation/appkit/nsscrollview/1403460-flashscrollers)
- [ChimeHQ ScrollViewPlus](https://github.com/ChimeHQ/ScrollViewPlus)
- [SwiftUI Field Guide: Overlay](https://www.swiftuifieldguide.com/layout/overlay/)
- [FIVE STARS: View Clipping in SwiftUI](https://www.fivestars.blog/articles/swiftui-clipping/)
- [GNUstep NSScrollView source](https://github.com/gnustep/libs-gui/blob/master/Source/NSScrollView.m)
