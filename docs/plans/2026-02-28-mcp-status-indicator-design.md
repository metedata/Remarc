# MCP Status Indicator — Design

## Problem

Remarc has a working MCP integration (5 tools for AI agents to read/resolve comments), but the popover UI has zero indication it exists. Users don't know they can ask their AI agent to interact with Remarc comments.

## Solution

A subtle status indicator in the popover footer that educates and enables the MCP workflow.

## Visual Element

**Location:** Footer, right of "Copy All" button, before the Spacer.

```
[ Copy All ]  [ ✦ MCP ]              [🗑] [📄]
```

- **Icon:** `sparkles.2` SF Symbol
- **Label:** "MCP" in 11pt medium
- **MCP ON:** Tinted `remarcPrimary`, full opacity. Same `FooterButtonStyle(restOpacity: 0.08, hoverOpacity: 0.14)`
- **MCP OFF:** `primary.opacity(0.35)` — present but visually inactive
- **`.help()` tooltip** (two lines): "MCP status\nLet AI agents read your comments through MCP"

## Tap Popover — Connected State

```
┌─────────────────────────────────┐
│  🟢 Connected                   │
│                                 │
│  Let AI agents read your        │
│  comments through MCP.          │
│                                 │
│  [ Copy Prompt ]                │
└─────────────────────────────────┘
```

- Green `circle.fill` (6pt) + "Connected" 12pt medium
- Description: 12pt regular, `primary.opacity(0.6)`
- "Copy Prompt" pill button: `remarcPrimary` tint, 11pt medium
- Copies: `I left review comments using Remarc. Use the remarc_list_sessions and remarc_list_comments tools to see them, then resolve each one.`
- Toast: "Prompt copied" via `ToastManager.shared`
- Padding: 12pt, matches delete confirmation popover

## Tap Popover — Not Connected State

```
┌─────────────────────────────────┐
│  ⚫ Not Connected                │
│                                 │
│  Enable MCP in Preferences to   │
│  let AI agents read comments.   │
│                                 │
│  [ Open Preferences ]           │
└─────────────────────────────────┘
```

- Gray `circle.fill` + "Not Connected"
- "Open Preferences" button opens Preferences window

## Behavior

- Only visible in footer (footer hidden on empty state)
- Reads `MCPManager.shared.isEnabled` for state
- Popover uses `.popover(isPresented:, arrowEdge: .top)` — same pattern as delete confirmation
- Dismissed on outside tap (standard SwiftUI)
