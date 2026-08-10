---
title: Webhooks
description: Send Remarc comment events as HTTP POST JSON to Zapier, Make, n8n, IFTTT, Slack, or any other endpoint that accepts JSON.
---

Webhooks are the handoff path for tools that do not speak MCP: Remarc sends comment events to any URL as an HTTP POST with a JSON body. That covers Zapier, Make, n8n, IFTTT, Slack incoming webhooks, and anything else that accepts JSON. Configure them in the **Webhooks** tab in Settings.

## Add a webhook

Click **Add Webhook** to open the editor:

- **Name**: identifies the webhook in the list and when sending a card manually.
- **URL**: must be a valid http or https URL.
- **Events**: check which events this webhook receives. All are on by default.
- **Signing secret** (optional): when set, requests include a `webhook-signature` header (HMAC SHA-256, Standard Webhooks format). `whsec_` secrets are supported.
- **Custom payload template** (optional): replace the default JSON body with your own, for example for Slack incoming webhooks.

Each webhook in the list has a test button (paperplane), edit and delete buttons, and an enable switch. After a delivery, a status icon appears next to the name; hover it for the delivery time and, on failure, the error.

## Events

Subscribable events and when each fires:

| Event | Fires when |
| --- | --- |
| `comment.created` | A comment is created |
| `comment.updated` | A comment's text or attachments change, or it moves to another session |
| `comment.status_changed` | A comment's status changes to anything other than resolved |
| `comment.resolved` | A comment is resolved |
| `comment.deleted` | A comment is deleted |
| `comment.sent` | You send a card manually (see below) |
| `webhook.test` | You click the test button |

`comment.sent` and `webhook.test` ignore the event checkboxes; subscriptions only filter the automatic events.

## Send a card manually

Every comment card has a paperplane action. Click it, pick one of your enabled webhooks, and Remarc delivers the comment immediately as a `comment.sent` event. A toast confirms the send.

## Delivery

Remarc sends requests with `Content-Type: application/json` plus `webhook-id` and `webhook-timestamp` headers, and retries failed deliveries twice (after 2 and 10 seconds) with the same `webhook-id` so receivers can deduplicate. Any 2xx response counts as delivered; otherwise Remarc shows a failure toast and records the error on the webhook row.

The default payload contains the event name, an ISO 8601 timestamp, app name and version, the session's id and name, and the full comment object including its short ID.

## Custom payload templates

A template replaces the default body. `{{placeholder}}` tokens are substituted with JSON-escaped values, so a template like this stays valid JSON:

```json
{"text": "{{comment.text}} ({{comment.status}})"}
```

Available placeholders:

| Placeholder | Value |
| --- | --- |
| `{{event}}` | Event name, e.g. `comment.created` |
| `{{timestamp}}` | ISO 8601 delivery time |
| `{{comment.id}}` | Full comment UUID |
| `{{comment.shortID}}` | Short ID (first 5 characters) |
| `{{comment.text}}` | The comment text |
| `{{comment.selectedText}}` | The quoted selection, if any |
| `{{comment.status}}` | `open`, `handedOff`, `inProgress`, or `resolved` |
| `{{comment.source}}` | Source app name |
| `{{comment.resolutionSummary}}` | Summary provided when resolved |
| `{{comment.resolvedBy}}` | Who resolved it |
| `{{session.id}}` | Session UUID |
| `{{session.name}}` | Session name |

Remarc leaves unknown placeholders in place untouched. See [statuses and history](/basics/statuses-and-history/) for what each status means.
