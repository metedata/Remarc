// #popclip
// name: Remarc
// identifier: com.metepolat.remarc.popclip
// description: Comment on the selected text in Remarc.
// popclipVersion: 4586
// macosVersion: "14.0"
// keywords: comments feedback review annotation notes agent
// icon: scale=80 file:remarc-logo.svg
// app: { name: Remarc, link: "https://remarc.app", bundleIdentifiers: ["com.metepolat.Remarc"], checkInstalled: true }

// Deliberately sends no selection text. Remarc re-reads its own selection, which
// keeps the comment text identical to the hotkey path, preserves the selection
// rectangle so the composer anchors correctly, and leaves a hostile page with
// nothing to inject. The only value passed is the page URL, which Remarc cannot
// see for itself in browsers without the Chrome extension. Do not add a title:
// Remarc has no field for it and stopped parsing it in Task 4.
export const action: Action = {
	code(_input, _options, context) {
		const url = new URL("remarc://comment");
		if (context.browserUrl) {
			url.searchParams.set("url", context.browserUrl);
		}
		// activate:false keeps focus in the source app, matching how Remarc's own
		// hotkey behaves; its composer is a non-activating panel.
		popclip.openUrl(url.href, { activate: false });
	},
};
