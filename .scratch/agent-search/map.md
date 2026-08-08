# Agent-aware search: sessions, MCP, and friendly JSONL

Label: wayfinder:map

## Destination

A buildable spec at `.scratch/agent-search/spec.md` with decisions locked for three staged strands — (1) **agent sessions search**: index chat sessions from every installed agent, full-text search inside transcripts, Enter resumes the session in its agent; (2) **friendly JSONL**: session transcripts render as readable chat plus a generic structured JSONL preview; (3) **MCP**: catalog search over configured servers/tools → Floodlight exposed as an MCP server → invoking MCP tools from the launcher — plus orthogonal `ready-for-agent` implementation issues on fpcMotif/floodlight. Building happens after the map closes.

## Notes

- Domain: Floodlight, a keyboard-first Spotlight replacement for macOS (SwiftUI + FFF fuzzy search). Engine target `Sources/FloodlightEngine`, app shell `Sources/Floodlight`; pipeline is `SearchCoordinator`.
- Standing decisions from charting (user, 2026-08-08):
  - **Coverage**: all nine installed agents — pi, omp, crush, codex, Claude Code, amp, opencode, droid, gemini — behind a per-agent adapter seam; the named five (pi, omp, crush, codex, claude) ship first. Claude Desktop cloud chats: research feasibility, include if reachable.
  - **Enter on a session hit = resume in its agent** at the session's project dir; secondary actions: open transcript view, reveal the .jsonl in Finder.
  - **JSONL**: both transcript-as-chat rendering and a generic structured record-by-record JSONL preview.
  - **MCP**: all three strands wanted, staged — catalog search, then Floodlight as an MCP server (generalizing the user's existing pi-fff wiring), then invoking MCP tools from the launcher.
  - **Priority order**: sessions search → MCP catalog → MCP server → MCP invoke.
- Store facts from the charting probe (2026-08-08): pi `~/.pi/agent/sessions/<proj>/*.jsonl`; omp `~/.omp/agent/sessions/<proj>/*.jsonl`; codex `~/.codex/sessions/YYYY/MM/DD/*.jsonl`; Claude Code `~/.claude/projects/<proj>/*.jsonl`; crush and opencode use SQLite; amp/droid/gemini stores unverified.
- Skills: /grilling + /domain-modeling for grilling tickets; the viewer ticket uses the mattpocock-skills prototype skill; research findings land in `research/`.
- The user writes terse, typo-heavy messages — interpret charitably and confirm understanding with concrete options.
- Tracker: local markdown per mattpocock-skills conventions — tickets in `issues/`, research findings in `research/`.
- Related map: [smarter-search](../smarter-search/map.md) (still open) owns web-intent routing and local AI. Sessions-search UX must coordinate with its filter-tab and keyword-trigger questions, not duplicate them.

## Decisions so far

<!-- one line per closed ticket: gist + link -->

- [Claude Desktop cloud chats feasibility](issues/03-claude-desktop-chats.md) — not feasible live: no stable local conversations store (Electron caches only, LevelDB locked by the running app) and no consumer API; spec says Claude Code JSONL is the live source, with claude.ai's manual data export accepted as an optional static import ("last imported" timestamp), no scraping. Findings: [research/claude-desktop-chats.md](research/claude-desktop-chats.md).
- [MCP configuration landscape across agents](issues/04-mcp-config-landscape.md) — all ten agents declare servers in JSON (Codex: TOML), stdio or remote, but paths/scoping diverge widely; tool lists are mostly live-only (pi's `mcp-cache.json` and Claude Desktop DXT manifests are the static exceptions). Catalog indexer: static-parse configs, redact secret-shaped fields, respect enable/approval flags, live-probe only where no cache exists, watch files (resolving Nix symlinks). Findings: [research/mcp-config-landscape.md](research/mcp-config-landscape.md).
- [Session resume mechanics per agent](issues/02-session-resume-mechanics.md) — resume-by-id exists everywhere except amp (server-side threads; fallback to transcript view): pi/omp `--resume <path>` (path form skips cwd checks), crush `--session <id> --cwd`, codex `resume <uuid>`, claude `--resume <id>`, droid `--resume <id>`, opencode `--session <id>`, gemini `--resume` (project-hash-scoped). Launch via Ghostty/Kitty with explicit working directory and absolute binary paths (GUI PATH lacks the Nix profile). Findings: [research/session-resume-mechanics.md](research/session-resume-mechanics.md).
- [Agent session stores and schemas](issues/01-agent-session-stores.md) — seven of nine agents have local transcripts: JSONL for pi/omp/codex/claude/droid/gemini (varied schemas: `parentId` chains, date-sharded rollouts, title events/indexes), SQLite for crush (per-project `.crush/crush.db`) and opencode; amp is server-side only. Normalized adapter model: `{id, agent, title, projectDir, createdAt, updatedAt, parentSessionId, messages[role, text, thinking, toolUse, timestamp]}`. Cowork's `claude-code-sessions/` is an extra Claude Code root. Findings: [research/agent-session-stores.md](research/agent-session-stores.md).

## Not yet specified

- Handling of secrets inside transcripts (redact at index time? skip tool outputs?) — hangs on the indexing architecture.
- Packaging of the transcript viewer (in-panel preview vs a QuickLook extension target) — hangs on the prototype.
- Whether session hits participate in smarter-search's web-fallback promotion and filter tabs — hangs on sessions-search UX plus that map's routing spec.
- Per-agent adapter packaging (own SPM target vs part of FloodlightEngine) — hangs on the indexing architecture.

## Out of scope

- **Implementing the spec** — the destination is the spec plus handoff tickets; building is post-map work.
- **Composing/sending new messages to agents from Floodlight** — resume only; Floodlight is not becoming a chat client.
- **Web-intent routing and local AI search** — owned by the smarter-search map; returns there, not here.
