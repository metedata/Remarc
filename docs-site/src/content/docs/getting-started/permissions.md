---
title: Permissions
description: What each macOS permission enables in Remarc, what still works without it, and how to grant it later in System Settings.
---

Remarc asks for three macOS permissions during onboarding: Accessibility, Microphone, and Screen Recording. Each unlocks a specific capability; if one is missing, only its own features stop working.

## Accessibility

Accessibility is the permission behind Remarc's core feature. Remarc uses the Accessibility API to read the text you select in other apps, so the Comment tooltip can appear and your comment can quote the selection. It also powers the optional fn/globe key binding for [dictation](/voice/dictation/).

Without it, [commenting on selections](/basics/commenting-on-selections/) does not work and the fn/globe key option is unavailable. Screenshot comments, quick notes, and the Chrome extension still work.

During onboarding, click Allow and macOS will ask you to open Accessibility settings. Enable Remarc there. If the alert was previously dismissed, use the Open Settings fallback in Remarc or go to System Settings > Privacy & Security > Accessibility.

## Microphone

The Microphone permission covers all voice features: voice input comments, system-wide dictation, and Crit Mode. macOS shows its standard microphone prompt when you click Allow.

Without it, voice features cannot record. Everything text- and screenshot-based works normally.

To grant it later, open System Settings > Privacy & Security > Microphone and enable Remarc.

:::note
Voice features require macOS 26 (Tahoe) or later. On older versions the voice controls are hidden, but onboarding still requests the Microphone permission.
:::

## Speech Recognition

Speech Recognition backs transcription with the built-in Apple Speech engine. It is not a row in the onboarding window; if macOS asks for it, grant it to keep the Apple Speech engine working.

To grant it later, open System Settings > Privacy & Security > Speech Recognition and enable Remarc.

## Screen Recording

Screen Recording enables screenshot comments only. Remarc captures just the region you drag-select, at the moment you capture it.

Without it, screenshot capture fails. Every other feature works.

To grant it later, open System Settings > Privacy & Security > Screen & System Audio Recording and enable Remarc. If macOS offers Quit & Reopen after you change the setting, accept it; Remarc resumes onboarding after relaunch.

## Not a permission: the local WebSocket

The [Chrome extension](/chrome-extension/) talks to Remarc over a WebSocket server on `127.0.0.1:9274`. One extension-owned connection serves all tabs, remains on your Mac, and does not require Chrome’s per-site “Apps on Device” permission. macOS shows no permission dialog for this connection. If another app is already using the port, the Chrome Extension tab in Settings shows the conflict with a Retry button.
