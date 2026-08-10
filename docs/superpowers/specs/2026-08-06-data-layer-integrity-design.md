# Data Layer Integrity - Design Spec (rev 2)

Extracted from the wake-on-comment review loop (Codex adversarial rounds 1-5,
2026-08-06); rev 2 after round 5 attacked rev 1 directly.

Rounds 2-5 repeatedly found blockers that are **pre-existing defects in
Remarc's data layer**, not defects of any new feature. They are live today and
affect every writer (app, MCP tools, hooks, webhooks). Wake-on-comment is a
hard dependent of this work: its payload instructs agents to call
`remarc_set_status`, which today drives traffic straight through the bug in
Bug 2.

## Bug 1 - Lost updates: no writer holds a transaction

Every writer separates "read the document" from "write the document" and
writes a whole-document snapshot built from data read earlier:

- The Swift app mutates a long-lived in-memory `appState` and later writes a
  full snapshot (debounced).
- The TypeScript layer exposes `readAppState()` and `writeAppState()` as
  independent calls; MCP tools and hooks call them minutes or milliseconds
  apart.

Consequences, all reproducible today: an agent resolves a comment, the app's
next UI-triggered save silently reverts it; two MCP processes updating
different comments clobber each other; a pending UI edit is discarded when
`reloadFromDisk` cancels the debounced save after an external write.

**Fix - a real transaction boundary, used by every writer:**

1. `withDocument(mutate)` in the TypeScript layer: acquire an advisory
   `flock` on `comments.json.lock`, read fresh from disk, apply `mutate` to
   the raw document, write to `comments.json.<pid>.<random>.tmp`, atomic
   rename, release. **The lock spans read through rename** - the round-5
   finding was that locking only the write still loses updates. `readAppState`
   / `writeAppState` remain for read-only callers but every mutating tool is
   migrated to `withDocument`.
2. The Swift app performs the same transaction: under the lock, re-read from
   disk, rebase its pending mutations onto that fresh document, write, rename,
   release. Rebasing requires knowing what changed, so `PersistenceManager`
   tracks dirty entity ids (`scheduleSave()` gains the id of the entity the
   caller mutated); at save time it applies only those entities onto the fresh
   document. Entities untouched since load are never written back from stale
   memory.
3. `reloadFromDisk` flushes any pending save through (1) before replacing
   `appState`, instead of cancelling it.
4. Change detection uses a content hash, not `mtime + size` (a same-size
   replacement within a filesystem timestamp granularity is otherwise
   invisible).
5. Lock acquisition timeout: 2s, then abandon the write and surface an error;
   never write outside the lock. All lock holders are short-lived
   (read+mutate+rename, no network, no user interaction), so contention is
   bounded.

## Bug 2 - Closed-set serializers strip unknown fields

`plugins/shared/data.ts` parses into modeled types and re-serializes a closed
field set, dropping anything it does not model - today that includes the
top-level `orphanedImages` and `transcriptions` arrays that the Swift app
persists, plus any newer Comment/Session field. Any hook or MCP write can
therefore silently delete user data (transcription history, orphaned image
records). This is a live data-loss bug, independent of any new feature.

**Fix - full-document passthrough on both sides:**

- TypeScript: retain the parsed raw document, mutate only the narrow target,
  re-serialize preserving unknown keys at document, Session, and Comment
  level.
- Swift: the `Codable` implementations for `AppState`, `Session`, and
  `Comment` retain an `unknownFields` bag decoded from and re-encoded into the
  JSON, so an older app build cannot strip fields a newer build wrote
  (round-5 finding 10).
- CI round-trip fixtures on both sides, including fixtures with fields the
  code deliberately does not model.

## Bug 3 - Shared temp filename

The shared writer renames through a fixed `comments.json.tmp`, so concurrent
writers interleave through one path. Use `comments.json.<pid>.<random>.tmp`
(subsumed by the `withDocument` transaction above).

## Addition - compare-and-set status writes

`remarc_set_status` gains an optional `expectedStatus` parameter. Inside
`withDocument`, the tool fails cleanly (`"already <status>"`, no mutation) if
the comment's current status differs. This makes "exactly one agent claims a
comment" expressible; without it, two agents can both read `handedOff` and
both write `inProgress` (round-5 finding 2). Existing callers that omit
`expectedStatus` behave exactly as today.

## Scope and sequencing

Ship as one plugin release plus one app release. Order is free - each fix
independently reduces data loss - but **both must precede wake-on-comment**,
which depends on Bug 2's fix (its payload requires a status write) and on the
compare-and-set addition. No user-visible behavior change, no schema change.

## Testing

- Cross-process harness: Swift writer, TypeScript writer, and MCP tool
  mutating concurrently across thousands of interleavings; assert zero lost
  updates.
- Regression: agent resolves a comment, UI edits another - both survive.
- Regression: pending UI edit plus inbound external write - both survive
  (reload no longer cancels).
- Compare-and-set: concurrent claim attempts, exactly one succeeds.
- Round-trip fixtures with unmodeled fields, both languages, both directions.
- Crash injection during rename: the file is always wholly old or wholly new.
- Lock timeout path: writer surfaces an error and leaves the file untouched.
