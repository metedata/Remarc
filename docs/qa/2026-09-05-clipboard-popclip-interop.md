# Clipboard interoperability QA — 5 September 2026

Implemented on `codex/clipboard-popclip-interop`, based on `a88f101`.

Ordinary clipboard restores now use `org.nspasteboard.TransientType` without adding `ConcealedType`. Originally confidential data keeps its original marker and payload. Every restore checks ownership immediately before writing all saved items together. A real Copy/Cut cancels an automatic selection read that has not started; input during an active read is detected with Core Graphics counters, including copies of identical text.

Live testing found that Figma publishes one logical Copy with multiple ownership changes, sometimes after the previous 100 ms timeout. The reader therefore accepts staged writes of the same text, waits for approximately 60 ms of quiet, and polls for up to approximately 400 ms. Standard accessibility reads and the existing list of apps requiring clipboard fallback remain unchanged.

The same restoration primitive protects dictation and paste-last-transcription. Their snapshot is taken immediately before borrowing the clipboard, and a competing clipboard write cancels a pending paste as well as a later restore. Transcriptions remain in Remarc's existing history; temporary paste contents now carry the transient marker.

## Automated validation

`swift test` in `app/RemarcPackage` passed **293 XCTest tests and 198 Swift Testing tests**, with zero failures. This includes 25 clipboard tests, with additional parameterized cases.

Coverage includes ordinary/empty/confidential clipboards, original marker payloads, rich text, HTML, image and file representations, multiple items, Unicode, unreadable or changing snapshots, delayed/promised data, late staged writes, repeated and overlapping operations, different-text background writes, identical-text intentional copies before observation and during settling, clicking away without copying, and unsettled timeout handling. These tests use unique private pasteboards, never the user's general clipboard.

The Debug app build passed with the deterministic worktree DerivedData path and was relaunched after each successful app build. `git diff --check` passed. Existing unrelated build warnings were not changed.

## Live validation

Ran the worktree Debug app with installed PopClip 2026.8 (6159) and Raycast on the user's Mac. User settings, including Remarc's Hotkey Only mode and PopClip's automatic appearance, were preserved. Native foreground input was used for selection gestures and keyboard races because background app-targeted events do not reliably reach global input monitors.

| Case | Observed result |
| --- | --- |
| Repeated TextEdit highlighting without acting, including Unicode | Original clipboard contents and representations unchanged. |
| Raycast history filtered to all QA fixture strings | Only the deliberately copied fixture was present; no highlight-only, temporary baseline, or restored entries. |
| Real Copy 20 ms after highlighting in TextEdit | Intended text remained on the clipboard with its normal rich-text formats. The pending automatic read was cancelled. |
| Installed PopClip Remarc action | Actual action button opened the correct quote in the rebuilt app. The clipboard did not change; debug output confirmed the cached selection was used. |
| Figma text-layer selection requiring clipboard fallback | Correct quote appeared in Remarc; all saved rich-text/HTML/text bytes and types were restored. Repeated on the final build. |
| Figma fallback with a confidential original | Original text, marker, and marker payload survived exactly. |
| Real Copy 20 ms and 130 ms after invoking Remarc in Figma | The intended selection stayed on the clipboard; no stale restore replaced it. The 130 ms case was repeated on the final build. |
| Figma with no copyable selection | Failed copy returned to Quick Note and preserved the confidential original clipboard exactly. |
| Isolated final Figma fallback after removing its QA history entry | Clipboard restored correctly; Raycast showed **No Results** for the captured text afterward. |

PopClip automatic appearance was briefly disabled to isolate Figma's staged writes, then re-enabled and verified. No Figma design content was edited; the original Icon page and selected node were restored. All QA drafts were discarded. Only history entries demonstrably created during this session were removed. The disposable TextEdit document was moved to Trash. The latest saved user clipboard was restored, including a newer user copy received during the session.

## PopClip extension assessment

No extension change is needed. `popclip/Remarc.popclipext/Config.ts` sends `remarc://comment`, optionally with browser page context, and uses `activate: false`. It does not copy text or send the quote in the URL. The changed clipboard behavior belongs in the app. Existing extension/package/privacy tests passed, and the installed extension's actual action was exercised twice. Browser-context behavior was reviewed and covered by the existing tests; this run did not manually exercise every browser.

## Limits of the evidence

All cases above passed; this is not a guarantee that every app or clipboard manager can never observe a temporary synthetic copy. The source app publishes that copy itself, and its write does not inherit a marker previously placed on the clipboard. An app responding after the polling deadline can still publish a late copy. Same-text background writes with no new input during the initial staged-copy window are inherently ambiguous because the pasteboard does not expose a logical Copy transaction identifier. A write arriving between the final ownership check and the write itself is also not protected by an atomic compare-and-swap API.

The longer fallback wait is a deliberate behavior change for slow or unreadable apps. Normal accessibility selection reads do not incur it. Dictation's clipboard helper and cancellation conditions were covered by tests and code review; microphone capture/transcription was not manually exercised in this clipboard QA run. No release, merge, push, or deployment was performed.

References: [NSPasteboard marker conventions](https://nspasteboard.org/), [restoration convention clarification](https://github.com/NSPasteboard/NSPasteboard.org/pull/4), [Apple changeCount documentation](https://developer.apple.com/documentation/appkit/nspasteboard/changecount), [PopClip JavaScript API](https://www.popclip.app/dev/api/interfaces/PopClip.html).
