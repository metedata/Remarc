---
title: Dictation
description: Dictate into any focused text field on your Mac with Remarc, push-to-talk or hands-free, transcribed entirely on your device.
---

Dictation types what you say into whatever text field is focused, in any app. It works system-wide and runs entirely on your Mac.

:::note
All voice features require macOS 26 (Tahoe) or later. On older versions the Voice settings tab and dictation shortcuts are hidden.
:::

Turn it on with the **Enable dictation** toggle in Settings > Voice. When the toggle is off, Remarc ignores the dictation shortcuts entirely. Dictation needs the Microphone permission - see [permissions](/getting-started/permissions/). It uses the engine selected in the same tab - see [transcription engines](/voice/transcription-engines/).

## Shortcuts

Dictation has three shortcuts:

| Action | Default shortcut |
| --- | --- |
| Push to talk | `Ctrl+Option+D` (hold) |
| Hands-free | `Ctrl+Option+H` |
| Paste last dictation | `Ctrl+Option+L` |

## Push to talk

Push to talk records only while you hold the shortcut. Hold `Ctrl+Option+D`, speak, and release; Remarc transcribes your speech and pastes it into the focused text field.

## Hands-free

Hands-free recording keeps going until you stop it. A floating pill stays on screen with Stop and Cancel buttons. Pick how it starts with the **Hands-free mode** picker in Settings > Voice:

| Mode | Behavior |
| --- | --- |
| Single tap | Tap the push-to-talk shortcut to start hands-free recording. |
| Double tap | Double-tap to start hands-free recording. A single tap does a quick record-and-paste. |
| Custom shortcut | A separate shortcut (default `Ctrl+Option+H`) starts hands-free recording. Tapping the push-to-talk shortcut does a quick record-and-paste instead. |

To discard a recording without pasting, press `Escape` or click the X on the pill.

## Use the fn key

Either the push-to-talk or the hands-free shortcut can be bound to the fn (globe) key instead, with the **Use fn🌐 key** toggle next to it. Only one shortcut can hold the fn key at a time: enabling it on one moves it off the other, and a toast confirms the move. The fn key option relies on the Accessibility permission.

## Paste last dictation

Paste last dictation re-pastes your most recent transcription: press `Ctrl+Option+L` and it lands in the focused text field again. Remarc restores your clipboard contents right after the paste.

## History

Past transcriptions live in the popover: click the clock icon in the header, then switch to the **Dictation** tab. Hover a row to copy or delete it. The **History retention** setting in Settings > Voice controls how long transcriptions are kept: 1 day, 1 week (default), 1 month, or 3 months.
