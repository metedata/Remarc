# Releasing Remarc Updates

Automated release process for Remarc, including signing, notarization, GitHub Release publishing, and Sparkle auto-updates.

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  GitHub Actions │────▶│ GitHub Releases  │────▶│   Sparkle App   │
│  (Build & Sign) │     │ (Remarc.zip)     │     │  (Auto-update)  │
└─────────────────┘     └──────────────────┘     └─────────────────┘
         │                                                 │
         ▼                                                 │
┌─────────────────┐                                        │
│  GitHub Gist    │◀───────────────────────────────────────┘
│  (appcast.xml)  │
└─────────────────┘
```

- **Binary (.zip)**: uploaded as an asset on the tagged GitHub Release.
- **Appcast**: lives on a GitHub Gist. `SUFeedURL` in every shipped binary points at this gist. The workflow updates the gist on each release.
- **Signing**: Developer ID + Apple notarization for Gatekeeper; EdDSA signatures for Sparkle.
- **Website download**: after the first public source release, `remarc.app/download` 302-redirects to `https://github.com/metedata/Remarc/releases/latest/download/Remarc.zip`. During repository recreation, `website/public/_redirects` deliberately keeps the shipped 0.5.1 R2 URL as a non-breaking fallback; switch it only after the newer GitHub asset is live.

## GitHub Secrets Required

Repository → Settings → Secrets and variables → Actions.

| Secret | Description |
|--------|-------------|
| `CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate |
| `CERTIFICATE_PASSWORD` | Password for the .p12 |
| `PROVISIONING_PROFILE` | Base64-encoded provisioning profile |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing updates |
| `GIST_PAT` | GitHub Personal Access Token with `gist` scope |
| `NOTARIZE_KEY` | App Store Connect API key (.p8 contents) |
| `NOTARIZE_KEY_ID` | Key ID from App Store Connect |
| `NOTARIZE_ISSUER_ID` | Issuer ID from App Store Connect |

The release workflow no longer writes to R2, so `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `R2_ACCOUNT_ID` can be removed from Actions secrets. Do not disable the bucket or delete its versioned objects: during repository recreation `/download` still serves the signed 0.5.1 archive from R2, every existing appcast entry through 0.5.1 points there, and extension 0.3.0 is still served there. After the GitHub cutover, retain those objects for old clients and stable historical links. New extension releases ship as GitHub Releases on `extension-v{VERSION}` tags, always created with `--latest=false` so they never hijack the app's `releases/latest/download/Remarc.zip` URL - see `.claude/skills/release-extension/SKILL.md`.

## Releasing a New Version

The recreated public repository begins with source fields `0.5.1` / `12`, but
that exact shipped build is already in the live appcast and remains available
from the historical R2 URL. Do **not** rebuild or republish `0.5.1` / `12` from
the newer open-source snapshot. The first automated source release must use a
genuinely newer pair, such as `1.0.0` / `14`.

### Via GitHub Actions (normal path)

1. **Actions** tab → **Release** workflow → **Run workflow**
2. Fill in:
   - **Version:** e.g. `1.0.0` (marketing version)
   - **Build number:** must be higher than previous (check `app/Config/Shared.xcconfig`)
   - **Release notes:** one non-empty plain line for a single announcement, or one `- ` prefixed line per change for a list.
3. Run.

Or via CLI:
```bash
gh workflow run release.yml \
  -f version="1.0.0" \
  -f build_number="14" \
  -f release_notes="Remarc's public release."
```

### What the workflow does (in order)

1. Require the repository to be public and the dispatch to come from `main`, validate semantic-version/build inputs against the live appcast, and fail closed if that version/build or a conflicting tag or GitHub Release already exists.
2. Checkout the current `main`, select Xcode 26.2, and bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Shared.xcconfig`.
3. Install the Developer ID certificate and provisioning profile into an ephemeral keychain.
4. Archive and export the Release configuration using only versions pinned in `Package.resolved`. A build phase verifies the committed `mcp/vendor/remarc-mcp.js` against its recorded SHA-256 and bundles it; there is no npm build.
5. Submit the app to Apple notarization, staple the accepted ticket, and validate the signed app with `codesign`, Gatekeeper, and `stapler`.
6. Create `Remarc.zip`, create `Remarc.zip.sha256`, extract the archive, and repeat the signature, Gatekeeper, and stapling checks on the extracted app.
7. Sign the zip with the `sign_update` tool from the resolved Sparkle 2.9.5 artifact, recording its EdDSA signature and exact byte length.
8. Commit the version bump to `main`, confirm that the remote did not move during the build, and create the annotated `vX.Y.Z` tag.
9. Create a draft GitHub Release containing exactly `Remarc.zip` and `Remarc.zip.sha256`; verify both asset names and sizes.
10. Download the current appcast from the gist, prepend the candidate item, and fully validate it while the GitHub Release is still a draft.
11. Publish the verified draft as the latest GitHub Release.
12. Publish the already-validated appcast immediately afterward.
13. Re-download and byte/checksum-verify both GitHub assets, then parse the published appcast and verify its version, build, URL, Sparkle signature, and byte length.
14. Remove temporary certificate, provisioning-profile, notarization-key, Sparkle-key, and keychain files even if an earlier step fails; the hosted runner is also discarded after the job.

Sparkle clients see the new version only after step 12 completes. The release is published before the appcast so an update enclosure never intentionally points at a missing asset.

### Failure recovery

The workflow is deliberately fail-closed: it never overwrites a tag, release, or release asset.

- If it fails before creating a GitHub Release, rerun it with the exact same inputs. A matching version commit and tag at the current `main` can be resumed safely.
- If it leaves a draft release, inspect its assets first. Delete that draft only if you intend to rerun the entire workflow; otherwise finish and verify the draft manually.
- If the GitHub Release is already published but the appcast step fails, do not rerun the workflow and do not delete the published release. Repair and validate the gist appcast separately using the published asset's exact Sparkle signature and length.
- If any existing tag or release differs from the requested version or current release commit, stop and resolve the mismatch rather than moving or replacing it.

The automated path pushes its version commit directly to `main`. If branch protection disallows that push, first land a change containing only the requested `Shared.xcconfig` version/build bump and make the resulting `main` commit subject exactly `Release vX.Y.Z`. Dispatch the workflow with the same values; it will verify that commit and resume at the tag step instead of trying to push another version commit.

## URLs

| Resource | URL |
|----------|-----|
| Latest download (stable) | `https://github.com/metedata/Remarc/releases/latest/download/Remarc.zip` |
| Versioned download | `https://github.com/metedata/Remarc/releases/download/vX.Y.Z/Remarc.zip` |
| Website download (302 → GitHub after the first public release) | `https://remarc.app/download` |
| Appcast feed | `https://gist.githubusercontent.com/metedata/0bbb8342e141a8c41a9f1c0bfaab8f81/raw/appcast.xml` |
| GitHub Releases page | `https://github.com/metedata/Remarc/releases` |

## One-Time Setup Reference

### Developer ID Certificate

1. Create a **Developer ID Application** certificate at [developer.apple.com](https://developer.apple.com/account/resources/certificates/list).
2. Export as `.p12` from Keychain Access with a password.
3. `base64 -i certificate.p12 | pbcopy`.
4. Add to secrets as `CERTIFICATE_P12`. Password goes in `CERTIFICATE_PASSWORD`.

### Sparkle EdDSA Key

- Public key lives in `app/Remarc/Info.plist` under `SUPublicEDKey`.
- Private key goes into the `SPARKLE_PRIVATE_KEY` secret.
- **Do not rotate** without shipping a new build first, or existing installs will reject updates signed with the new key.

### GitHub Gist PAT

1. Create a token at [github.com/settings/tokens](https://github.com/settings/tokens) with only the `gist` scope.
2. Add as `GIST_PAT`.

### Notarization Credentials

1. App Store Connect → Users and Access → API Keys → create a key with "App Manager" role.
2. Add `.p8` contents to `NOTARIZE_KEY`, Key ID to `NOTARIZE_KEY_ID`, Issuer ID to `NOTARIZE_ISSUER_ID`.

## Troubleshooting

### Build fails with signing error
- Verify `CERTIFICATE_P12` is base64-encoded correctly (`file certificate.p12` should report "PKCS#12").
- Check certificate hasn't expired in the Apple Developer portal.

### Notarization fails
- Workflow fetches the notarization log via `xcrun notarytool log` on failure and prints it.
- Common causes: an entitlement the notary disagrees with, or a dependency binary that isn't signed.

### Appcast not updating
- Check `GIST_PAT` scope includes `gist` and isn't expired.
- Gist ID is hardcoded as `0bbb8342e141a8c41a9f1c0bfaab8f81`; verify it still belongs to the right account.

### Empty release notes in Sparkle's update dialog
- Release notes may be one plain line or one or more `- ` prefixed bullet lines.
- The workflow rejects blank input, mixed plain text and bullets, and multiline plain text.

### Users not seeing updates
- Check the binary's `Info.plist` has the correct `SUFeedURL` and `SUPublicEDKey`.
- `curl -sL "$SUFeedURL"` should return the appcast XML.
- The most recent `<item>` in the appcast must have a valid EdDSA signature and a downloadable enclosure URL.
- If you ever change `SUPublicEDKey` between versions, users on the older version cannot upgrade and must manually re-download.

## Manual intervention

Prefer recovering the workflow state described above over rebuilding or publishing a release by hand. A manual intervention must preserve the same ordering and validation gates: notarize and staple; validate the app before and after archiving; create and verify both release assets in a draft; publish the release; then update and validate the appcast last. Never move an existing release tag or overwrite an existing release asset to make a failed run pass.

## Version History

See the [GitHub Releases page](https://github.com/metedata/Remarc/releases) for the authoritative list.
