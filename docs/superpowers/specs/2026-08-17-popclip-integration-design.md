# PopClip Integration — Design

**Date:** 2026-08-17
**Status:** Approved (scope, distribution, and UI confirmed by Mete). Revised twice: once after an adversarial review and a primary-source pass over PopClip's docs and shipped extensions, once after a second review that replaced the URL payload with a selection re-read.

## Goal

Let people who already live in PopClip trigger a Remarc comment from the PopClip bar, without Remarc growing a second selection-detection stack or a competing preferences mode.

This is additive: Remarc keeps its own tooltip and hotkey. Users who want a single popup set Detection mode to Hotkey Only themselves, and we point them at that from the setting and the docs.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Scope | Additive trigger only | Remarc already is a PopClip-alike (`SelectionMonitor` says so in its own header). A substitutive mode means a new preferences concept, onboarding copy, and a not-installed fallback. |
| Transport | Custom URL scheme `remarc://` | `popclip.openUrl` needs no entitlement, so the extension carries no unsigned-extension warning. Shell script or CLI alternatives both trip that warning. |
| URL handler | `NSAppleEventManager` / `kAEGetURL` | `application(_:open:)` is not reliable for this app's scene shape. |
| **Payload** | **No selection text in the URL. Remarc re-reads its own selection.** | Removes the injection vector rather than guarding it, and recovers the selection rectangle PopClip cannot provide. See "Payload". |
| Extension shape | Module-based `Config.ts`, `popclipVersion: 4586` | What every comparable companion-app extension in Pilotmoon's directory uses. |
| Hotkey Only behaviour | Suppress the tooltip, keep the monitor running | The mode named after the hotkey must not degrade the hotkey. See "Detection mode". |
| Distribution | Bundled in the app, installed from Preferences | Ships and versions with Remarc, no external review. |

## The prerequisite: Detection mode is inert

`selectionDetectionMode` (`.auto` / `.hotkeyOnly`) is persisted by `SettingsManager` and rendered as the "Detection mode" picker at `PreferencesWindowController.swift:322`, but **no runtime code reads it**. Repo-wide, the only references are the picker, `SettingsManager` itself, and one stale comment at `SelectionMonitor.swift:95`.

- `AppController.setup()` calls `startMonitoring()` unconditionally (`AppController.swift:63`); the only gate is pause (`AppController.swift:434-440`).
- `SelectionTooltipWindowController` subscribes to `$currentSelection` with no mode check (`SelectionTooltipWindowController.swift:37-47`).

Picking "Hotkey Only" therefore still shows the tooltip on every selection. A standalone bug worth fixing regardless of PopClip, and this feature's story depends on it.

### Fix: gate the tooltip, not the monitor

Add a single `shouldShowSelectionUI` accessor (not paused, and mode is `.auto`) and have `SelectionTooltipWindowController` consult it, dismissing any visible tooltip when it becomes false. `SelectionMonitor` keeps running.

The accessor rather than an inline check because every future `$currentSelection` subscriber would otherwise have to remember the gate. Verified there is exactly one subscriber today — `FloatingActionButton` is Crit Mode only — so the tooltip is genuinely the only selection-driven surface, and gating it suppresses every popup.

Stopping the monitor instead was considered and rejected. `readCurrentSelection()` prefers the stored selection and otherwise falls through to `readSelectionViaClipboard()`, which the code documents as the weaker path (`SelectionMonitor.swift:87-88`):

> "more reliable than a fresh read during a Carbon hotkey callback, where simulated Cmd+C can fail due to physical modifier keys still held"

Stopping the monitor would put every hotkey press on simulated Cmd+C. A mode called "Hotkey Only" that degrades the hotkey is disqualifying, and the user-visible promise that matters is "no popup."

**Accepted cost:** in `.hotkeyOnly`, Remarc still reads selections via AX continuously. Someone could reasonably read the setting as "stop reading my selections." That stronger meaning is a deliberate non-goal; delivering it requires strengthening the hotkey's fresh-read path (AX before clipboard) first, which is its own work with its own regression risk. It is also now a hard requirement of this feature — see "Payload".

**Help text** changes to match what the setting does, replacing "Auto detects text selections automatically. Hotkey only waits for your shortcut.":

> Auto-detect shows the Remarc popup as soon as you select text. Hotkey only hides the popup and waits for your shortcut.

## Payload

**The URL carries no selection text.** Remarc resolves the selection itself, exactly as the hotkey does.

The first draft sent `text` in the URL. That is an injection vector: custom schemes are web-reachable, so any page could open a composer prefilled with attacker-authored content that the user might save into a session Claude Code and Codex read through MCP. Guarding it required a per-install token, substituted into a copied `Config.ts` at install time, never rotated, failing silently on mismatch — precisely the class of install machinery this project has already been burned by, where "every serious defect across four review rounds lived in migration machinery rather than in installing."

Re-reading the selection removes the vector instead of guarding it. A hostile page can then only open a composer containing the user's own real selection, which is the feature working as intended. No token, no size cap, no encoding surface.

It also turns out to be better on the merits:

- **The selection rectangle is recovered.** The stashed selection retains the `screenRect` from its AX read, so the composer anchors to the selection rather than floating at the cursor, and the Chromium region-context query fires normally. Both were losses in the first draft.
- **Text matches the hotkey path exactly.** PopClip's `input.text` is post-trim and post-regex-narrowing; re-reading guarantees a PopClip-triggered comment and a hotkey-triggered comment on the same selection produce identical text.

### Resolution order

1. `SelectionMonitor.currentSelection`, if live.
2. A recently-cleared selection, within a grace window (below).
3. A fresh read via the existing `readCurrentSelection()` clipboard path. This is what covers a cold launch, where no selection history exists.
4. Give up, log, and do nothing. Do not fall back to `showStandaloneNote()`.

### The grace window

Clicking PopClip's bar is a plain click, and `SelectionMonitor` treats a `clickCount` 1 mouse-up as deselection, clearing `currentSelection` (`SelectionMonitor.swift:145-150`). So by the time the URL arrives the live selection is already gone.

`SelectionMonitor` stashes the selection it clears along with a timestamp, and exposes `readRecentSelection(maxAge:)` returning it if fresh. Scoped to a new method so the hotkey path is unchanged: the hotkey must not resurrect a selection the user deliberately dismissed. A 2 second window is ample for a click-to-URL round trip that takes tens of milliseconds.

This makes a running `SelectionMonitor` a hard dependency of the feature, which is a second, independent reason the Detection mode fix gates the tooltip rather than the monitor.

### What the URL does carry

```
remarc://comment
  ?url=<browser url, optional>
```

Nothing else. App name and bundle identifier come from Remarc's own selection read, so PopClip only supplies what Remarc cannot see: the page URL, for browsers without the Chrome extension, chiefly Safari and Arc.

An earlier draft also carried `title`. It was dropped during implementation: because the selection is re-read locally, `source` comes from `TextReader`, so the title had no consumer, and `WebContext` has no field for it. Giving it one would touch the persisted `comments.json` contract that requires coordinated app and plugin releases - disproportionate for a nice-to-have on one trigger path. Parsing untrusted input that nothing reads is worse than not carrying it.

`url` is optional, length-capped by UTF-8 bytes, restricted to http(s), rejected if it carries userinfo (so `https://accounts.google.com@evil.com` cannot masquerade), and **untrusted** - a page can spoof it. The residual risk is a comment recording a page URL the attacker chose, on text the user themselves selected, only if the user saves. Accepted. Live Chrome-extension context takes precedence when present; these values only populate a minimal `WebContext` when it is absent.

## Architecture

```
PopClip bar → Config.ts action → popclip.openUrl(remarc://comment?…, {activate:false})
                                        ↓
                        kAEGetURL Apple Event handler
                                        ↓
                        RemarcURLHandler (parse, validate, queue)
                                        ↓
                  SelectionMonitor: live → recent → fresh read
                                        ↓
              CommentInputController.shared.showForSelection(_:)
```

`showForSelection` is already the shared entry point for the hotkey, the tooltip, and (via `showForWebElement`) the Chrome extension. PopClip becomes a fourth caller and needs no new composer code. Because the selection carries a real `screenRect`, it takes the same branch the hotkey path takes, including the Chromium region query.

### Transport

Register the `kAEGetURL` Apple Event handler in `applicationWillFinishLaunching`, plus `CFBundleURLTypes` in `Info.plist`.

`application(_:open urls:)` is **not** the mechanism. Under the SwiftUI lifecycle it is a known-flaky path — empty URL arrays, spurious windows, behaviour differing between `Window` and `WindowGroup`. Remarc's only scene is `Settings { EmptyView() }` (`RemarcApp.swift:11-13`), matching neither configuration most reported fixes assume. The Apple Event handler predates all of it and does not care about scenes.

### Which copy of Remarc gets the URL

Registering a scheme means every installed Remarc bundle claims it, and LaunchServices picks one. That is a live hazard here, not a hypothetical:

- Debug builds in `.worktrees/` are launched routinely, sometimes by other sessions, and Sparkle can replace a lower-versioned worktree build in place.
- AppMover means a Downloads copy and an `/Applications` copy legitimately coexist during install.

If the URL lands on a duplicate, `RemarcApp.swift:43-47` terminates that process and the URL is dropped. Combined with a resolution failure the symptom is a button that does nothing, which is the worst signature to debug.

Handling:

- The handler logs the receiving bundle's path on every URL, so a misroute is visible in the debug log rather than silent.
- Development instructions in the docs page note that `remarc://` may reach a stale worktree build, and that verifying the receiving binary is the first diagnostic step. This mirrors the existing project guidance about verifying which binary is running before trusting a live test.
- A URL arriving in a process that is about to terminate as a duplicate is dropped, not forwarded. Forwarding is possible but is coordination machinery for a transient state, and the AppMover window is seconds long.

### Handler behaviour

- **Unknown host:** ignore. `comment` is the only host, so the scheme has room to grow.
- **Paused:** respect `SettingsManager.shared.isPaused` and drop, matching the hotkey path. Silence is correct here; pausing is deliberate.
- **Cold launch:** queue. `applicationWillFinishLaunching` may set `shouldSkipSetup` and terminate the process, so a URL arriving before `AppController.setup()` completes must be held and replayed after setup, and discarded if this process is terminating as a duplicate.
- **Oversized `url`:** drop it rather than truncating, measured in UTF-8 bytes.

### Known gap: failure is silent

If the selection cannot be resolved, the user clicks and nothing happens. This is not solved, and the spec should not pretend otherwise.

`ToastManager` is the obvious surface but is only rendered by `PopoverContentView` and `AnnotationToolbarView`, so a toast is invisible unless the popover is already open — a pre-existing gap that also swallows several `GlobalHotkey` messages, filed separately. Real feedback needs a surface Remarc does not have, and adding one is new UI requiring its own approval. For now: log, and revisit once that surface exists.

## The extension package

`Remarc.popclipext/` containing a single module-based `Config.ts` plus the Remarc mark, following Craft, UpNote, Agenda, and Tana in Pilotmoon's own directory:

```ts
// #popclip
// name: Remarc
// identifier: com.metepolat.remarc.popclip
// description: Comment on the selected text in Remarc.
// popclipVersion: 4586
// icon: remarc-logo.svg
// app: { name: Remarc, link: https://remarc.app,
//        bundleIdentifier: com.metepolat.Remarc, checkInstalled: true }

export const action: Action = {
  code(_, __, context) { /* build URL from context, popclip.openUrl(url, { activate: false }) */ },
};
```

Notes behind each piece:

- **Module-based is fine and idiomatic.** A forum summary claims module extensions cannot reach `browserUrl`; that restriction applies to the global `popclip.context` during module evaluation, not the `context` argument passed into `code()`. Craft and UpNote both read `context.browserUrl` this way.
- **`popclipVersion: 4586`, not 4170.** 4170 is the minimum for plain JavaScript actions. TypeScript module support arrived around 4225, and shipped module configs in the directory declare 4516 through 5997, with 4586 the most common. 4586 also comfortably clears `app.checkInstalled`, which Anybox uses at 4151.
- **`activate: false`** on `openUrl` should stop LaunchServices pulling app-level focus off the source app, keeping this path consistent with the hotkey path. The docs do not state the default, so **verify empirically**, including whether it still launches Remarc when not running and whether a freshly launched, non-activated `LSUIElement` app can take key focus for typing.
- **`app.checkInstalled`** is close to moot, since the extension can only be installed from inside Remarc's Preferences. Kept for the case where Remarc is later removed. It does **not** address the silent-failure gap above.
- **No entitlements.** The unsigned warning appears when an unsigned extension "contains Shell Script actions or AppleScript actions, or has entitlements." A module JS action with none avoids it; `openUrl` requires none.
- **Identifier must not use a reserved prefix.** `com.pilotmoon.popclip.extension.*` is Pilotmoon's, gated behind `AllowUnsignedReservedPrefixes`.
- **Icon** is `assets/remarc-logo.svg`.
- **URL construction** uses `new URL()` and `searchParams.set()`, as Craft and UpNote do, which handles percent-encoding.

The package source lives at `popclip/Remarc.popclipext/` in the repo root, alongside `mcp/`, and is copied into the built app by a **shell script build phase** mirroring the existing "Copy MCP Server" phase.

Not Copy Bundle Resources, and not the SPM package. `Package.swift:32` declares `.process("Resources")` for `RemarcFeature`, so a `.copy` of a subpath inside it is not expressible without restructuring. And the Xcode project uses synchronized folder groups (`PBXFileSystemSynchronizedRootGroup`, with an empty `PBXResourcesBuildPhase`), which would recurse into a `.popclipext` directory and flatten its contents into `Resources/` rather than copying it as a package. A `cp -R` in a script phase is unambiguous, and the project already establishes that pattern for bundling non-Swift payloads.

## Install affordance

Preferences → App, immediately under the Detection mode picker:

- A `CalloutView`: *"Using PopClip? Set this to Hotkey Only and add the Remarc PopClip extension so only one popup appears on selection."*
- An "Install PopClip Extension" button with hover and click states.

Both shown only when PopClip is present, detected with `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.pilotmoon.popclip")`. A synchronous, spawn-free check — unlike the Claude Code and Codex plugin detectors there is no CLI to run and no hang risk, so none of the `ProcessRunner` rules apply.

Install calls `NSWorkspace.shared.open` on the bundled package directly, with no temp copy — a path inside a sealed, signed bundle works fine for PopClip, so the earlier "copy out only if required" hedge is resolved without one. No install dialog appears, verified directly including with a real `com.apple.quarantine` xattr set on a copy of the extension. The unsigned-extension warning is gated on capabilities (shell script actions, AppleScript actions, entitlements); this config declares none, which is why the install is silent.

**Repeat installs are idempotent.** Verified against PopClip's own extension store: it logs a history row per action, but the visible extension list keeps exactly one entry per identifier no matter how many times the button is pressed.

No uninstall affordance and no installed-state detection. PopClip owns the extension once installed.

## Docs

One page on docs.remarc.app: what the extension does, how to install it, the Hotkey Only step, and a note that a Remarc that is not running may miss the first click.

## Risks

| Risk | Mitigation |
| --- | --- |
| `activate: false` does not behave as assumed | Verify before building on it. Fallback is explicit focus restoration after dismiss. |
| Grace window too short or too long | 2 seconds, scoped to the URL path only, so a wrong value cannot affect the hotkey. |
| Selection unresolvable at cold launch | Falls through to the clipboard read, which works because the selection is still live in the source app. |
| `remarc://` reaches a stale build | Receiving bundle path logged on every URL; documented as the first diagnostic. |
| Repeat install misbehaves | Verify before shipping the button. |
| PopClip absent | Callout and button hidden. |
| Failure is invisible to the user | Not solved. Logged, and recorded as a known gap pending a toast surface that works outside the popover. |

## Testing

**Unit:**
- URL parsing: valid, unknown host, absent optional params, oversized `url` by byte length, non-http(s) scheme, userinfo-bearing url, form-urlencoded `+` decoding in both directions.
- Resolution order: live selection preferred; recent stash used when live is nil; fresh read when both are nil; nothing when all three fail.
- Grace window: a stash older than the window is not returned; the hotkey path does not consult the stash.
- Cold-launch queueing: a URL received before setup completes is replayed once, after setup; a URL received in a `shouldSkipSetup` process is dropped.
- Paused state drops the URL.
- Detection mode: `.hotkeyOnly` shows no tooltip and leaves the monitor running; the hotkey still resolves a selection; switching to `.hotkeyOnly` dismisses a visible tooltip.

**Manual:**
- Round trip from a native app (Notes) and a browser (Safari, Chrome), confirming text, app, and page URL land on the comment, and that the composer anchors to the selection rather than the cursor.
- Chrome with the extension installed, confirming region context still attaches and PopClip's `url` does not override it.
- Arc, where `browserUrl` is unavailable, degrades rather than breaks.
- Focus returns to the source app after save and after dismiss.
- Remarc not running: click the PopClip button and confirm the clipboard fallback still produces a comment.
- Install end to end with the unsigned-extension warning at its default, confirming no warning appears; then press Install a second time.

## Out of scope

- A quick-save action that skips the composer.
- Submission to the PopClip Extensions Directory.
- An uninstall button or installed-state detection.
- A substitutive mode that disables Remarc's detection automatically when PopClip is present.
- Making `.hotkeyOnly` stop reading selections entirely. Now doubly out of scope: the payload design depends on the monitor running.
- A toast surface that works outside the popover. Filed separately; this feature's failure feedback waits on it.
- Origin validation on the existing WebSocket server. Same threat class, pre-existing, filed separately.
