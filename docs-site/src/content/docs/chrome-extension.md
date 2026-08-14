---
title: Chrome extension
description: Install the Remarc Web Context extension and capture web elements or page regions with React, CSS, and accessibility context attached.
---

The Remarc Web Context extension attaches page context to your comments: the React component you clicked, its styles, accessibility attributes, and more. Once installed, two actions capture from any page: Grab Element and Select Region.

## Install and connect

1. Install the extension from [remarc.app/chrome-extension](https://remarc.app/chrome-extension). It works in Chrome, Arc, Brave, Edge, Vivaldi, and Opera.
2. Make sure the Remarc app is running. The extension makes one extension-owned connection to localhost port 9274 and shares it across your tabs. There is no pairing step or per-site “Apps on Device” permission.

:::note
Tabs that were already open before you installed or updated the extension cannot connect. Reload them once afterward.
:::

Settings > Chrome Extension shows the connection status and the port the app is listening on.

## Grab Element

Grab Element captures a single element on the page. Press `Option+Shift+G`, or click Grab Element in the extension popup. As you move the mouse, elements highlight under the cursor. Click one to capture it: the comment composer opens with the element's context attached. Press Escape to cancel.

## Select Region

Select Region captures a rectangle of the page. Press `Option+Shift+R`, or click Select Region in the popup, then drag over part of the page. The composer opens next to your selection, and the region stays highlighted on the page until you save or dismiss the comment. Press Escape to cancel.

Both actions create a Web Element comment. It behaves like any other comment: it belongs to a session and moves through [statuses](/basics/statuses-and-history/).

## What gets captured

Each capture saves up to five categories of context with the comment:

| Category | Included |
| --- | --- |
| React components | Component name, file path, hierarchy |
| Computed styles | CSS properties on the element |
| Accessibility | ARIA roles, labels, tab index |
| Layout & structure | Bounding box, parent, nearby elements |
| Element identity | CSS selector, HTML snippet, page URL |

All categories are on by default. Toggle each one under Captured Metadata in Settings > Chrome Extension. The toggles unlock after the extension connects for the first time.

## Change the shortcuts

Rebind Grab Element and Select Region in Settings > Chrome Extension, or in the [Shortcuts tab](/reference/keyboard-shortcuts/). Use `Ctrl+Shift` or `Option+Shift` combinations; `Cmd` is not supported in Chrome. Reset to Defaults restores `Option+Shift+G` and `Option+Shift+R`.

## The extension popup

Click the Remarc icon in the browser toolbar to open the popup. It shows:

- A status pill: Connected, Disconnected, or Paused.
- Grab Element and Select Region buttons with their current shortcuts.
- A pause button (visible while connected) to temporarily disable the extension.
- Extension Settings, which opens the app's Chrome Extension tab.

If the status is Disconnected, launch the Remarc app and click Retry. If Remarc is connected but the controls are unavailable on the current page, reload that tab once. Chrome Site Access can still be limited to selected sites as an optional privacy control, but normal operation does not require granting those sites access to apps on your device.

## Port conflicts

If another app is already using port 9274, Settings > Chrome Extension shows a warning with a Retry button. Quit the conflicting app, then click Retry to restart the connection.
