# Release Remarc

Create a new Remarc release using the automated GitHub Actions workflow.

## Instructions

When the user invokes this command, help them create a new release by:

1. **Check current version** - Read `app/Config/Shared.xcconfig` to get the current `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`

2. **Check recent releases and appcast** - Run `git tag -l 'v*' | sort -V | tail -5` and inspect the live appcast. Neither the requested marketing version nor build number may already be advertised.

3. **Prompt for release details** - Ask the user for:
   - **Version number** (e.g., "0.6.0") - must be an `X.Y.Z` semantic version higher than current
   - **Build number** - must be higher than current (suggest next number)
   - **Release notes** - what changed in this release

   **IMPORTANT: Release notes format**
   Release notes MUST be formatted as bullet points starting with `-` for proper appcast generation:
   ```
   - Fixed app hang issues during clipboard monitoring
   - Improved performance
   ```
   Plain paragraph text will result in EMPTY release notes in Sparkle's update dialog (the workflow fails the release if no `- ` bullet is present). Keep them to about 3 high-level summary bullets, not a per-commit changelog.

   **Never rebuild an advertised version:** the recreated public repository starts with source fields `0.5.1` / `12`, but that shipped build is already in the appcast. The first source release must use a genuinely newer pair, such as `0.6.0` / `13`.

4. **Confirm and execute** - Show the user what will happen:
   ```
   Release Summary:
   - Version: X.Y.Z (build N)
   - Notes: [their notes]

   This will:
   1. Update version in Shared.xcconfig
   2. Archive and export with Developer ID signing
   3. Notarize with Apple
   4. Sign update with EdDSA for Sparkle
   5. Commit the version bump and push a `v$VERSION` tag
   6. Create and verify a draft GitHub Release with Remarc.zip and Remarc.zip.sha256
   7. Generate and validate the candidate appcast while the release is still a draft
   8. Publish the release, then update appcast.xml on GitHub Gist
   ```

   **Note:** The workflow automatically preserves release notes from all previous versions in the appcast, so users see a cumulative changelog when updating.

5. **Run the workflow** - Execute:
   ```bash
   gh workflow run release.yml \
     -f version="VERSION" \
     -f build_number="BUILD" \
     -f release_notes="NOTES"
   ```

6. **Monitor progress** - Watch the workflow:
   ```bash
   gh run watch
   ```

7. **Verify release** - After completion:
   - Check the release asset is accessible: `curl -sIL https://github.com/metedata/Remarc/releases/download/vVERSION/Remarc.zip | head -1`
   - Download `Remarc.zip` and `Remarc.zip.sha256` from the release and verify them with `shasum -a 256 -c Remarc.zip.sha256`
   - Check the stable latest URL points at it: `curl -sIL https://github.com/metedata/Remarc/releases/latest/download/Remarc.zip | head -1`
   - Check appcast is valid XML:
     ```bash
     curl -fsSL "https://gist.githubusercontent.com/metedata/0bbb8342e141a8c41a9f1c0bfaab8f81/raw/appcast.xml" -o /tmp/remarc-appcast.xml
     xmllint --noout /tmp/remarc-appcast.xml
     ```
   - Check appcast updated: `curl -s "https://gist.githubusercontent.com/metedata/0bbb8342e141a8c41a9f1c0bfaab8f81/raw/appcast.xml" | grep VERSION`
   - **Verify release notes are not empty** - Check the appcast contains actual `<li>` items:
     ```bash
     curl -s "https://gist.githubusercontent.com/metedata/0bbb8342e141a8c41a9f1c0bfaab8f81/raw/appcast.xml" | grep -A 10 "What's New in Remarc VERSION"
     ```
     If you see empty `<ul></ul>` tags, manually fix the appcast using `gh gist edit`.
   - **Verify previous versions are preserved** - The appcast should contain notes for all versions (current + all previous). If any are missing, manually add them to the appcast gist.
   - **Verify minimum macOS matches the app** - The appcast `sparkle:minimumSystemVersion` should match `MACOSX_DEPLOYMENT_TARGET` in `app/Config/Shared.xcconfig`.

## Key URLs

- **Latest download (stable)**: `https://github.com/metedata/Remarc/releases/latest/download/Remarc.zip`
- **Versioned download**: `https://github.com/metedata/Remarc/releases/download/vVERSION/Remarc.zip`
- **Appcast Feed**: `https://gist.githubusercontent.com/metedata/0bbb8342e141a8c41a9f1c0bfaab8f81/raw/appcast.xml`

## Troubleshooting

**Build fails with signing error:**
- Ensure `CERTIFICATE_P12` is properly base64 encoded
- Check certificate hasn't expired
- Verify `CERTIFICATE_PASSWORD` is correct

**Notarization fails:**
- Check `NOTARIZE_KEY`, `NOTARIZE_KEY_ID`, `NOTARIZE_ISSUER_ID` secrets
- Ensure API key has App Manager role in App Store Connect

**GitHub Release creation fails:**
- The workflow intentionally refuses to overwrite a tag, release, or asset.
- If a draft exists, inspect its assets and workflow logs. Delete the draft only when deliberately restarting the same failed release.
- Never delete or replace a published release to make a rerun pass. Follow the failure-recovery section in `RELEASING.md`.

**Appcast not updating:**
- Check `GIST_PAT` has `gist` scope
- Gist ID: `0bbb8342e141a8c41a9f1c0bfaab8f81`

**Empty release notes in Sparkle update dialog:**
- Release notes must be formatted as bullet points starting with `-`
- Plain text paragraphs are NOT converted to list items
- To fix: manually edit the appcast gist with `gh gist edit 0bbb8342e141a8c41a9f1c0bfaab8f81`

For release-state recovery, see `RELEASING.md`.
