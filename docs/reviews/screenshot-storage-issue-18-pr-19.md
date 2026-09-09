# Screenshot storage: issue #18 and PR #19

Reviewed on 2026-09-09. Issue: https://github.com/metedata/Remarc/issues/18. Original PR head: `b727cd466ef64f56d5961ce6d719bfe1ccefe0c4`.

## Decision

Keep Application Support as the default. Let the user select a writable folder for new screenshots and pasted images. Preserve each saved image's original path and keep annotation files beside that image. Retain the original PR's relative paths for default storage and absolute paths for custom storage.

| Option | Assessment |
| --- | --- |
| Manual Save As | Exports a copy without updating the comment or agent reference; does not solve the issue. |
| Change the default globally | Disrupts existing installs and still cannot guarantee access for every local or remote agent. |
| Folder picker, preserve existing files | Selected. Meets the issue's explicit compatibility option without rewriting existing comments, leases, annotation families, or exported references. |
| Automatically migrate everything on folder selection | Avoid for this change. Migration requires copy verification and coordinated updates to comments, attachments, retained orphans, pending captures, and annotation families. Previously exported paths cannot be rewritten. A separately requested migration feature should be explicit and transactional. |
| Deliver images through MCP | Complementary. Inline images let a client inspect content without directly opening a local filesystem path. Storage selection still helps local tools that need the original file. |

## Findings in the original PR

- **P1: ownership escape.** `Constants.swift:162–163` accepted an absolute UUID image or sidecar anywhere on disk. Annotation replacement and deletion could reach files outside every selected folder, including through a symlink. A UUID filename alone does not establish ownership.
- **P1: unrelated file deletion.** `AnnotationMarkStore.swift:234–247` swept every orphan `*.base.png` and `*.marks.json` in the selected folder. Combined with unrestricted direct-child ownership, choosing an existing project folder could delete unrelated files.
- **P2: previous-folder cleanup omitted.** The sweep visited only default and current directories, leaving abandoned annotation sidecars in older custom folders.
- **P2: unusable selections were persisted.** The Settings setter swallowed directory errors and did not verify a write before activating the choice.
- **Lifecycle gap exposed by custom volumes.** Retention and lease cleanup discarded bookkeeping even if file deletion failed, making a disconnected drive or partial deletion permanently untracked.

## Implemented app behavior

`ScreenshotStorage.swift` centralizes allocation, path resolution, configuration, and ownership. Folder selection performs an actual write/delete probe before committing preferences. Captures use one settings snapshot and fail visibly when a custom folder is unavailable; they do not recreate a disconnected destination or silently fall back.

Ownership requires a known canonical root. Custom folders additionally require a generated UUID image/sidecar name. File symlinks, retargeted historical folders, and recursive deletion of image-named directories are refused. Legacy filenames in the dedicated default folder remain supported. Cleanup visits previous roots and retains failed image/lease deletions for retry.

Tests use both a temporary storage root and an isolated preferences suite, avoiding changes to the running app's screenshot setting. The Settings row exposes an accessible folder picker, reset action, full-path help, and inline errors.

## Skills and MCP

MCP already resolves default relative paths beside `comments.json` and preserves absolute custom paths. It should continue using each record's path, without consulting the app's current folder preference. App JSON exports already resolve both screenshots and pasted attachments correctly; no comments schema migration is needed.

The review found a pre-existing omission: MCP ignored pasted image attachments. The companion plugin change exposes attachment counts in lists, explicit paths in detail, and labeled image content in `remarc_get_comment`. Primary screenshots come first; duplicate paths are not read twice. Inline output is bounded by a shared 3.5 MB raw-byte budget and five images. Missing, unsupported, oversized, or inaccessible files retain their path and an explanation. The server reads referenced images only and does not discover annotation sidecars.

The canonical skill now teaches agents to inspect returned image content, fetch detail when a comment has attachments, and use returned paths without rebuilding them under `~/Library`. Folder selection affects future files and grants no new access to a remote or restricted client. Captured context remains untrusted reference data.

The app previously vendored plugin 0.13.1. The coordinated plugin **0.13.3 / MCP 0.3.3** starts from verified public 0.13.2, preserving newer tool metadata and skill safety guidance. Vendor synchronization copies the skill and dependency notices with the server and records hashes for the server and skill. Xcode verifies both hashes before packaging. Worktree builds resolve their own MCP server instead of an enclosing checkout's older server.

Updating the app does not update installed Claude Code, Codex, or OMP marketplace caches. Existing plugins already support custom primary screenshot paths; attachment delivery requires the companion update. The app and companion plugin are released together; installed marketplace clients still need to update their plugin cache.

## Validation

- **518 full-suite Swift tests passed:** 320 XCTest and 198 Swift Testing tests, including fresh-directory lease fixtures and dependency-notice provenance checks. Additional focused coverage included **106 tests:** 96 covering storage, annotation round trips, image cleanup, leases, settings, and exports; 10 covering worktree server selection and plugin-version consistency.
- **228 plugin tests passed:** MCP 90, hooks 101, wake 37. Runtime bundles built; MCP and wake typechecks, schema fixtures, public version consistency, notices, skill validation, and Claude marketplace validation passed. The release also removes an unsupported notification process option and updates the transitive fast-uri dependency to resolve the high-severity audit gate.
- **Built-server stdio regression reproduced and fixed:** the old app vendor returned zero images for a Quick Note with pasted attachments. `node scripts/smoke-mcp-images.mjs` now passes for both the vendored file and the actual app resource, verifying image bytes/MIME types, default/custom paths, pasted attachments, missing-file explanations, text-only lists, and path preservation through status writes. All fixtures are disposable; no live Remarc data is used.
- **Native app:** clean Debug build passed after the layout change; the final integrated build also passed and was relaunched. Live Settings verification opened the folder picker, chose `/tmp/remarc-screenshot-storage-ui`, confirmed the displayed path and reset action, and restored the default. The empty test folder and its test-only preference history were removed. Debug output confirms this build resolves its own worktree MCP server.
- **Package provenance:** the server and skill are pinned to the exact clean companion commit in `mcp/vendor/PROVENANCE.json`. CI exercises the packaged server over real stdio and checks that the distributed app notices match the canonical notice file.

- **Marketplace installs:** Claude Code 2.1.226, Codex 0.146.1, and OMP 17.3.4 were tested with disposable profiles. Copied plugin bundles and skills match the candidate, and cached MCP bundles pass the image smoke test.
- **Auxiliary surfaces:** Chrome 0.3.1 and PopClip require no protocol or package changes. The published Chrome ZIP exactly matches the source and its 62 tests pass. Webhook and JSON export retain each image's original path. Markdown exports now encode image destinations so folders containing spaces, parentheses, Unicode, percent signs, and Markdown delimiters remain readable; regression tests parse the Markdown and load the referenced PNG files.

Local validation does not establish OS Screen Recording authorization. Real PNG writes, annotation edits, exported paths, and MCP image delivery were tested; live capture and public signed artifacts are verified separately during release.

## Framework references

- Apple's [NSOpenPanel directory selection](https://developer.apple.com/documentation/appkit/nsopenpanel/canchoosedirectories) and sheet API were checked through Context7.
- Apple's [FileManager guidance](https://developer.apple.com/documentation/foundation/filemanager/iswritablefile(atpath:)) recommends attempting the operation and handling errors rather than treating an access preflight as proof. The folder probe validates selection; every later write still handles its own failure.
- MCP's [tool result specification](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) permits mixed text/image content. SDK transport usage was checked through Context7; the existing pinned dependency is preserved.
