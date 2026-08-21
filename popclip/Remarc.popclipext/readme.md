# Remarc

Add a Remarc action to PopClip and turn selected text into a contextual comment for your coding agent.

## Requirements

- [Remarc 1.2.0 or later](https://remarc.app/download)
- macOS 14 or later

## Use

1. Install and launch Remarc, then grant its requested Accessibility permission.
2. Select text in any app.
3. Click the Remarc action in PopClip.
4. Write your comment and press Command-Return to save it.

Remarc quotes the selection, records the source app, and keeps the comment locally until you choose to hand it to an agent or another integration.

## Avoid two selection popups

Remarc has its own selection tooltip. To use only PopClip's action bar, open **Remarc Settings > General** and set **Detection mode** to **Hotkey Only**.

## Privacy

The extension has no network entitlement and never transmits the selected text. It opens Remarc on the same Mac using the `remarc://comment` URL, and Remarc reads the selection locally through macOS Accessibility.

When invoked from a browser, the extension may also pass the current page URL to the local Remarc app so the saved comment can retain its source. See [Remarc's data and privacy guide](https://docs.remarc.app/reference/data-and-privacy/) for details.

## Help and source

- [PopClip setup guide](https://docs.remarc.app/basics/popclip/)
- [Remarc documentation](https://docs.remarc.app/)
- [Source code and issues](https://github.com/metedata/Remarc)

Remarc is created by Mete Polat at Metedata.

## Changelog

- 2026-08-21: Initial PopClip Extensions Directory release.
