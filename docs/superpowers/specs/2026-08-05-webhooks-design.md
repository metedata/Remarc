# Webhooks - Design Spec

Date: 2026-08-05
Branch: `webhooks`

## Goal

Any comment ("card") in Remarc can trigger any external service without per-service
integrations. Remarc emits generic outbound HTTP POST webhooks compatible with
Zapier Catch Hooks, Make, n8n, IFTTT, and direct incoming-webhook endpoints
(Slack, Discord) via payload templating.

## Scope (all phases, approved 2026-08-05)

1. Core engine: config model, dispatcher with retries, event emission from
   `PersistenceManager` mutators, old-vs-new diff in `reloadFromDisk()` so
   agent/MCP-driven changes also fire webhooks.
2. HMAC signing per the Standard Webhooks convention.
3. Preferences tab "Webhooks": list, add/edit sheet, enable toggle, test send.
4. Per-card manual "Send to webhook" action (approved by user with "all phases").
5. Payload templating with `{{placeholder}}` substitution for direct
   Slack/Discord-style endpoints.
6. Unit tests + live end-to-end integration test.

## Event types

| Event | Fired when |
|---|---|
| `comment.created` | New comment created |
| `comment.updated` | Text/attachments edited, or moved to another session |
| `comment.status_changed` | Status changes to anything except `resolved` |
| `comment.resolved` | Status changes to `resolved` (fires INSTEAD of status_changed) |
| `comment.deleted` | User- or agent-initiated soft delete |
| `comment.sent` | Per-card manual send (ignores event subscriptions) |
| `webhook.test` | Test button in Preferences |

Auto-cleanup paths (resolved-comment auto-delete, inactive-session cleanup,
session-delete cascades, history pruning) do NOT fire events - they are
housekeeping noise, not signal.

## Two writers, one dispatcher

- In-process: each `PersistenceManager` mutator calls
  `WebhookService.shared.dispatch(event, comment)` directly.
- Out-of-process (MCP server / CLI writes `comments.json` then posts the
  distributed reload notification): `reloadFromDisk()` snapshots old comments,
  decodes new state, and computes events via a pure diff
  (`WebhookEventDiff.events(old:new:)`): new id → created; `isDeleted`
  false→true → deleted; status change → resolved/status_changed; text change →
  updated. Ids vanished entirely (pruning) are ignored.

## Payload

JSON body, ISO8601 dates:

```json
{
  "event": "comment.resolved",
  "timestamp": "2026-08-05T12:00:00Z",
  "app": { "name": "Remarc", "version": "x.y.z" },
  "session": { "id": "...", "name": "Inbox" },
  "comment": { ...full Comment encoded with ISO dates... , "shortID": "a3f2b" }
}
```

Headers per Standard Webhooks: `webhook-id` (stable across retries),
`webhook-timestamp` (unix seconds), and - when a secret is configured -
`webhook-signature: v1,<base64 HMAC-SHA256 of "{id}.{timestamp}.{body}">`.
Secrets with the `whsec_` prefix are base64-decoded after stripping the prefix;
otherwise raw UTF-8 bytes are used as the key.

## Templating

Optional per-webhook template string. When set, it replaces the default body.
Placeholders (`{{event}}`, `{{comment.text}}`, `{{comment.shortID}}`,
`{{comment.status}}`, `{{comment.selectedText}}`, `{{comment.source}}`,
`{{comment.resolutionSummary}}`, `{{comment.resolvedBy}}`, `{{comment.id}}`,
`{{session.name}}`, `{{session.id}}`, `{{timestamp}}`) are substituted with
JSON-string-escaped values so templates like
`{"text": "Resolved: {{comment.text}}"}` stay valid JSON. Content-Type remains
`application/json`.

## Delivery

- `URLSession` POST, 10 s timeout per attempt.
- 3 attempts with 0 s / 2 s / 10 s backoff; success is any 2xx.
- Same `webhook-id` across retries (receiver-side dedup).
- Final failure: debug log + toast "Webhook '<name>' failed".
- Per-webhook last-delivery status kept in memory for the Preferences UI.

## Storage

`[Webhook]` JSON-encoded into `UserDefaults` via the existing `SettingsManager`
pattern (same as `ExtensionShortcut`). The signing secret lives in the same
struct: consistent with the app's storage model (comments.json is plaintext on
the same disk), and keeps config injectable for testing. Revisit Keychain if
Remarc ever syncs settings.

```swift
struct Webhook: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var url: String
    var isEnabled: Bool
    var events: Set<WebhookEventType>
    var secret: String?        // empty/nil = unsigned
    var customTemplate: String? // empty/nil = default JSON payload
}
```

## UI

- New `SettingsSection.webhooks` ("Webhooks", SF Symbol `bolt`), placed after
  MCP Integrations. Single location for all webhook controls.
- Section content: header + info `CalloutView` (works with Zapier/Make/n8n/
  Slack...), list of webhook rows (name, middle-truncated URL, last-delivery
  status icon, enable toggle, Test / Edit / Delete actions), Add Webhook button.
- Add/Edit is a sheet: name, URL, event checkboxes, secret field, optional
  template editor with placeholder reference. Buttons follow existing hover/
  click-state patterns; tooltips via `.help()`.
- Card action: paperplane icon appears alongside Copy/Edit/Move/Delete when at
  least one enabled webhook exists. One enabled webhook → sends directly;
  multiple → dropdown (same pattern as Move) listing webhooks. Toast confirms.

## Files

- `Models/Webhook.swift` - config struct + `WebhookEventType`
- `Services/WebhookService.swift` - dispatcher, signer, template renderer,
  payload builder, `WebhookEventDiff`
- `Services/PersistenceManager.swift` - event emission + reload diff
- `Services/SettingsManager.swift` - `webhooks` setting
- `Views/PreferencesWindowController.swift` - webhooks section
- `Views/WebhookEditorSheet.swift` - add/edit sheet
- `Views/CommentCardView.swift` - per-card send
- `Tests/RemarcFeatureTests/WebhookTests.swift` - unit tests

## Testing

- Unit: payload building, signature vector, template escaping, diff cases,
  event mapping, Codable round-trip.
- E2E: local catch server; config injected via `defaults write`; comment
  lifecycle driven through `comments.json` edits + reload notification (the
  MCP path) and through the app where drivable; verifies deliveries, headers,
  signature, retry behavior (500,500,200 → 3 attempts, same webhook-id).
  User data backed up and restored around the run.

## Review-driven decisions (2026-08-06)

Fixed after adversarial review:

- Reload diff suppresses comment deletes that are part of a session-delete or
  auto-dismiss cascade in the same reload (Claude Code wind-down), matching
  the silent in-app deleteSession cascade.
- Template rendering is single-pass over the original template, so literal
  `{{...}}` text inside comment content is never re-substituted.
- Signing secrets are trimmed; whsec_ payloads accept base64url and missing
  padding; a malformed whsec_ remainder falls back to the raw remainder bytes,
  never the transport prefix. The editor stores the secret trimmed and renders
  it in a SecureField.
- `timeoutIntervalForResource` capped at 30 s per attempt (the request timeout
  alone is an idle timer and would allow trickling responses to pin a delivery).
- Whitespace-only templates are treated as absent (trimmed on save, guarded at
  dispatch).
- Preferences test feedback comes from the per-row status icon; the toast
  overlay lives in the menu bar popover, which is closed while Settings is open.

Accepted limitations (documented, not bugs):

- Fire-and-forget delivery: in-flight deliveries (retry window up to ~24 s
  plus the 30 s resource cap) are dropped if the app quits; there is no
  persistent outbox.
- No per-endpoint ordering guarantee: each delivery retries independently, so
  a retried earlier event can arrive after a later one. Receivers should order
  by the payload timestamp or the webhook-timestamp header.
- Reload semantics: on an external reload, disk state wins over unsaved
  in-memory changes (pre-existing app behavior). Webhook events emitted from
  the reload diff describe the true resulting state, so a subscriber may see a
  change event followed by its reversal within the debounce window - an
  accurate history of what actually happened to the data.
