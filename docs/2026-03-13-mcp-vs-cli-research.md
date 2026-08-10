# MCP vs CLI: Should Remarc Add a CLI Interface?

**Date:** 2026-03-13
**Status:** Shelved — MCP criticism doesn't apply to Remarc's scale
**Context:** Research prompted by growing industry discourse around MCP limitations

## The Question

With companies like Perplexity publicly winding down MCP support in favor of API/CLI interfaces, and broad criticism of MCP's token bloat, reliability, and security — should Remarc add a CLI alongside its existing MCP server to give users options?

## Industry Landscape (March 2026)

### Companies Moving Away from MCP

- **Perplexity** (March 11, 2026): CTO Denis Yarats announced at Ask 2026 they're moving away from MCP internally in favor of REST APIs and CLIs. Cited context window consumption and auth friction. Ironic — they shipped an official MCP server just months prior.
- **Cloudflare**: Published a technical teardown calling MCP tool-calling "broken." Built "Code Mode" — converts MCP tools into a TypeScript API, cutting token usage by 32-81%. Compared MCP to "putting Shakespeare through a month-long class in Mandarin."
- **Anthropic itself**: Released guidance recommending filesystem/code-based "Skills" for tool calling instead of MCP. Daniel Miessler characterized this as Anthropic having "deprecated MCPs down to being like service directories." 150K tokens → 2K tokens (98.7% reduction).
- **mcp2cli** (open source): Converts MCP servers to CLI tools at runtime. 96-99% token reduction. Hit top of Hacker News, March 2026.

### The Core Criticisms

**Token/Context Bloat:**
- ScaleKit benchmark: simple task uses 1,365 tokens via CLI vs 44,026 via MCP (32x overhead). Difference is almost entirely schema — 43 tool definitions injected into every conversation, of which the agent uses one or two.
- Typical MCP server schema load: ~55,000 tokens before a single tool is called.

**Reliability:**
- ScaleKit: 25 runs — CLI achieved 100% success, MCP had 7 ConnectTimeout failures (72% success rate).

**Security:**
- April 2025: Invariant Labs — malicious MCP server exfiltrating WhatsApp history via "tool poisoning"
- May 2025: GitHub MCP hijacked through malicious issues; Asana data bleed between instances
- June 2025: Hundreds of MCP servers bound to 0.0.0.0, exposed to internet ("NeighborJack")
- July 2025: CVE-2025-6514 — critical command injection in `mcp-remote` (437K+ downloads)
- September 2025: Supply-chain attack on `postmark-mcp` npm package — BCC'd emails to attacker
- 43% of analyzed MCP servers have command injection vulnerabilities
- Simon Willison coined the "Lethal Trifecta": private data + untrusted content + external communication

### Arguments for Keeping MCP

- Linux Foundation governance (Agentic AI Foundation). OpenAI, Google DeepMind, Microsoft, AWS, Cloudflare as founding members.
- 97M monthly SDK downloads, 17K+ servers indexed, 76% of software vendors exploring/implementing.
- Standardized tool discovery — agents can find and use tools they weren't explicitly programmed to call.
- Solves enterprise integration complexity ("M×N problem").
- MCP Dev Summit announced for April 2-3, 2026 in NYC.

### Emerging Consensus

Not "MCP is dead" but "MCP is a registry/discovery layer, not an execution layer." CLI is the execution layer. The practical pattern: MCP for discovery, CLI/code for actual tool invocation.

## Why This Doesn't Apply to Remarc

The criticism targets large-scale, networked MCP integrations. Remarc's MCP server is a different beast:

1. **4 tools, not 40+.** Schema overhead is ~500 tokens, not 55K. The bloat problem is about massive API surfaces being crammed through tool schemas.
2. **Local stdio transport, not networked.** The 72% reliability figure comes from ConnectTimeout errors on remote servers. Remarc's MCP is a local process pipe — essentially 100% reliable.
3. **Reads/writes a local JSON file.** The security breach timeline is about servers connecting to WhatsApp, GitHub, databases with privileged access. Remarc's attack surface is minimal.
4. **Discovery is the value.** With MCP, the agent automatically knows Remarc exists and what it can do. A CLI would require the agent to be told about `remarc` via CLAUDE.md or system prompt — negating the token savings.

## CLI Design Explored (If Revisited)

If we decide to build a CLI later, the design direction explored was:

- **Audience:** AI agents (machine-optimized output, JSON mode, terse text)
- **Architecture:** Separate Swift binary bundled in `Contents/Resources/remarc`, auto-symlinked to `/usr/local/bin/remarc` on first launch (Ollama pattern)
- **Commands:** Mirror the 4 MCP tools — `remarc sessions`, `remarc comments`, `remarc resolve <id>`, `remarc reopen <id>`
- **Symlink approach:** Requires one-time admin password prompt. `/usr/local/bin` is on default macOS PATH for all users/shells. Self-healing on app launch if symlink breaks.
- **Precedent in codebase:** `tools/ax-inspect/` is a standalone Swift SPM executable that could serve as template.

### Why Not a Dual-Mode Binary

Considered embedding CLI into the Remarc app binary itself (`Remarc --cli sessions`). Rejected because:
- `isatty()` detection is fragile (breaks with pipes, cron, background processes)
- Code signing complications — single binary serving GUI and CLI confuses Gatekeeper and TCC
- AppKit lifecycle fights CLI usage (run loop, menu bar registration)
- Every successful app doing this (Ollama, Docker, VS Code) uses two separate binaries

## Sources

- [Perplexity CTO Moves Away from MCP](https://awesomeagents.ai/news/perplexity-agent-api-mcp-shift/)
- [Cloudflare: Code Mode — give agents an entire API in 1,000 tokens](https://blog.cloudflare.com/code-mode-mcp/)
- [MCP vs CLI Benchmark (ScaleKit)](https://www.scalekit.com/blog/mcp-vs-cli-use)
- [Anthropic Changes MCP to Filesystem-based Skills (Miessler)](https://danielmiessler.com/blog/anthropic-downplays-mcps)
- [Six Fatal Flaws of MCP (Scalifiai)](https://www.scalifiai.com/blog/model-context-protocol-flaws-2025)
- [Timeline of MCP Security Breaches (AuthZed)](https://authzed.com/blog/timeline-mcp-breaches)
- [Simon Willison: The Lethal Trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/)
- [mcp2cli on Hacker News](https://news.ycombinator.com/item?id=47305149)
- [MCP Joins the Linux Foundation](https://github.blog/open-source/maintainers/mcp-joins-the-linux-foundation-what-this-means-for-developers-building-the-next-era-of-ai-tools-and-agents/)
