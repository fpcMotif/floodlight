# Claude Desktop cloud chats feasibility

Type: research
Status: resolved

## Question

Claude Desktop app conversations live server-side on claude.ai. Are they reachable for local search at all? Investigate:

- What the local store at `~/Library/Application Support/Claude` actually holds (LevelDB/IndexedDB cache? full conversation text or fragments?) — inspect this machine.
- Export mechanisms: the claude.ai data-export flow (format, freshness, automation potential).
- Any API surface for listing/reading conversations available to an end user, and its terms.

Deliver: a feasible / not-feasible verdict with the recommended path if feasible (cache reader, periodic export import, or API), and what the spec should say if not (explicitly out — Claude Code JSONL only). Findings → [research/claude-desktop-chats.md](../research/claude-desktop-chats.md).

## Answer

**Not feasible for live local indexing.** The local store at `~/Library/Application Support/Claude` is an Electron profile with no SQLite: IndexedDB (1.1 MB) holds Cowork/agent-mode metadata (skills, MCP, job logs) and Local Storage (31 MB) is React Query UI caches — no stable conversations store, and the running app holds the LevelDB lock (schema undocumented and volatile, not a realistic reader target). The `claude-code-sessions/` and `local-agent-mode-sessions/` dirs there are Claude Code CLI runs launched from Cowork — they belong to the JSONL store inventory, not claude.ai chat. The only sanctioned path to full conversation text is claude.ai's manual data export (Settings → Privacy → Export data): human-triggered, emailed link expiring in 24 h, no API or automation. No consumer API lists claude.ai chats, and scraping the internal web API violates Consumer ToS §3 — not pursued.

**Recommendation:** index Claude Code JSONL as the live source; treat claude.ai chats as an optional, manually imported static `conversations.json` corpus with a visible "last imported" timestamp — no LevelDB reader, no scraping.

Full findings: [research/claude-desktop-chats.md](../research/claude-desktop-chats.md)
