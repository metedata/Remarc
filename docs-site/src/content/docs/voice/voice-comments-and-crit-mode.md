---
title: Voice comments & Crit Mode
description: Dictate a single Remarc comment with the voice input shortcut, or record a continuous critique that Crit Mode splits into comment cards.
---

Remarc gives you two ways to speak instead of type: voice input dictates one comment into the composer, and Crit Mode records a longer critique and turns it into separate comment cards.

:::note
All voice features require macOS 26 (Tahoe) or later, plus the Microphone permission - see [permissions](/getting-started/permissions/).
:::

## Voice input

Voice input starts with `Ctrl+Option+V`. Either hold the shortcut while you speak and release to stop, or tap it once to start recording and press it again to stop.

The transcription lands in the comment composer, where you can edit it before saving. If a composer is already open, the text is appended to it.

### Auto-save

With **Auto-save voice notes** on (Settings > Voice), comments created with the voice shortcut save themselves after a countdown. The **Auto-save delay** picker offers 1s, 1.5s, 2s (default), 3s, 4s, and 5s. During the countdown the Save button fills up; click it to save immediately, or press the voice shortcut again to start a new recording instead. Auto-save does not apply to comments you open manually.

### Recording behavior

Three more settings in Settings > Voice affect every recording:

| Setting | What it does |
| --- | --- |
| Sound effects | Plays start and stop sounds for voice recording. |
| Mute audio while recording | Mutes system audio when you start recording and restores it when you stop. |
| Prefer Mac built-in mic | Uses known studio USB mics when present; otherwise prefers the Mac built-in microphone over AirPods and headset mics. |

## Crit Mode

Crit Mode is for longer feedback passes: press `Ctrl+Option+M` or click the mic button in the popover header, then talk through everything you see. Remarc records continuously, showing a live waveform. When you stop, it transcribes the recording and splits it so each point becomes its own comment card, ready to triage or hand to an agent.

The first time you start Crit Mode, a one-time intro explains the flow; check "Don't show again" to skip it in the future.

Crit Mode and dictation are mutually exclusive: starting one cancels the other.

Both features transcribe on your Mac using the engine you picked - see [transcription engines](/voice/transcription-engines/).
