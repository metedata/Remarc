---
name: release-extension
description: Package and release the Chrome extension - bump version, zip, publish as a GitHub Release, update web page
user_invocable: true
---

# Release Chrome Extension

Package the Remarc Chrome extension and publish it as a GitHub Release on `metedata/Remarc`.

## Steps

1. **Check current version** - Read `extension/manifest.json` to get the current `version`

2. **Check what changed** - Run `git log --oneline` on the extension directory since the last version bump to see what's new:
   ```
   git log --oneline -- extension/
   ```

3. **Prompt for version** - Ask the user what version to release (suggest next patch/minor based on changes)

4. **Bump version** - Update `version` in `extension/manifest.json`

5. **Package** - Create a zip with the extension files inside a `remarc-extension/` folder:
   ```bash
   mkdir -p /tmp/remarc-ext
   rm -rf /tmp/remarc-ext/remarc-extension
   cp -R extension/ /tmp/remarc-ext/remarc-extension/
   cd /tmp/remarc-ext
   zip -r Remarc-Extension-VERSION.zip remarc-extension/
   ```

6. **Commit and push the manifest bump first** - so the release tag points at a commit containing the released source:
   ```bash
   git add extension/manifest.json
   git commit -m "Release extension vVERSION"
   git push
   ```

7. **Create the GitHub Release** - on its own `extension-v` tag, and **ALWAYS with `--latest=false`**:
   ```bash
   gh release create extension-vVERSION /tmp/remarc-ext/Remarc-Extension-VERSION.zip \
     --repo metedata/Remarc \
     --title "Remarc Chrome Extension vVERSION" \
     --latest=false \
     --notes "- what changed"
   ```

   **NEVER omit `--latest=false`.** GitHub's `releases/latest` is repo-global; without the flag this release becomes "latest" and `releases/latest/download/Remarc.zip` (the app's /download redirect and README link) starts 404ing for every visitor and update check.

8. **Update web page** - Update `website/public/chrome-extension/index.html`:
   - Update the download URL to `https://github.com/metedata/Remarc/releases/download/extension-vVERSION/Remarc-Extension-VERSION.zip`
   - Update the version in the `download-meta` div

9. **Verify**:
   ```bash
   curl -sIL https://github.com/metedata/Remarc/releases/download/extension-vVERSION/Remarc-Extension-VERSION.zip | head -1
   curl -sIL https://github.com/metedata/Remarc/releases/latest/download/Remarc.zip | head -1
   ```
   Both must return 200: the first proves the extension asset is live, the second proves the app's latest URL was not hijacked.

10. **Commit and push** the web page change

11. **Clean up** - Remove temp files:
    ```bash
    rm -rf /tmp/remarc-ext
    ```

## Key Details

- **Tag pattern**: `extension-v{VERSION}` - separate namespace from the app's `v{VERSION}` tags.
- **Download URL pattern**: `https://github.com/metedata/Remarc/releases/download/extension-v{VERSION}/Remarc-Extension-{VERSION}.zip`
- **Web page**: `website/public/chrome-extension/index.html`
- **Manifest**: `extension/manifest.json`
- **Zip must contain a `remarc-extension/` folder** (not loose files) - users unzip and load this folder in Chrome
- **History**: versions up to 0.3.0 were served from Cloudflare R2 (`releases.remarc.app/Remarc-Extension-{VERSION}.zip`); the old 0.3.0 zip stays there so existing links keep working
