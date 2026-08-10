# Security Policy

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please email **metepolat.a@gmail.com** with a description of the issue, steps to reproduce, and the Remarc version. Do **not** open a public GitHub issue for security problems.

You can expect an acknowledgement within 7 days. Critical issues are prioritized for a fix release; you will be kept informed of progress.

## Scope

In scope:

- The shipped Remarc app (this repository)
- The bundled MCP server (`mcp/vendor/`) and its source in [remarc-agent-plugins](https://github.com/metedata/remarc-agent-plugins)
- The Chrome extension (`extension/`)

Out of scope:

- The static website content (`website/`)
- Third-party dependencies (report upstream, but a heads-up is appreciated if Remarc's usage is affected)

Remarc runs with Accessibility, Screen Recording, and Microphone permissions, so reports about ways a malicious process or web page could abuse Remarc's access are particularly valuable.
