# Research: Are claude.ai conversations (via Claude Desktop) reachable for local search indexing?

Date: 2026-08-08
Scope: read-only inspection of this machine's `~/Library/Application Support/Claude`, plus review of Anthropic's official data-export docs and API/ToS boundaries.

## Verdict

**NOT FEASIBLE for live/local indexing of full claude.ai chat text.** There is no local, stable, always-current copy of claude.ai conversation content on disk, and there is no sanctioned API to fetch it either. The only sanctioned path to conversation text is Anthropic's manual, email-delivered data export (`conversations.json` inside a zip), which is a point-in-time snapshot, not a live source.

**Recommended path for Floodlight's spec:** Index Claude Code JSONL transcripts only as a *live* local source (already the target of the sibling `research-session-stores` effort). Treat claude.ai/Claude Desktop chat history as an *optional, manually imported static corpus* — a user can periodically request a claude.ai data export, drop the resulting `conversations.json` into a watched folder, and Floodlight indexes that snapshot like any other document. Do not attempt to read Electron LevelDB/IndexedDB stores or scrape claude.ai; both are unreliable and/or against Anthropic's Consumer Terms.

---

## 1. What `~/Library/Application Support/Claude` actually holds

Inspected on this machine (Claude Desktop actively running, PID 49108, macOS). This is a standard Electron app profile directory — Chromium's per-profile storage layout, plus Anthropic-specific "Cowork"/agent-mode directories.

### Top-level layout (relevant parts)
```
Claude/
├── IndexedDB/https_claude.ai_0.indexeddb.leveldb/   # 1.1 MB — LevelDB, per-origin IndexedDB
├── IndexedDB/https_claude.ai_0.indexeddb.blob/      # 1.8 MB — IDB blob overflow store (1 blob file found)
├── Local Storage/leveldb/                            # 31 MB  — LevelDB, per-origin localStorage
├── Session Storage/                                   # 208 KB — LevelDB, sessionStorage
├── Cache/, Code Cache/, GPUCache/, DawnGraphiteCache/ # Chromium disk caches — HTTP/asset caches, not app data
├── claude-code-sessions/<org>/<workspace>/*.json      # Claude Code CLI sessions run *inside* Claude Desktop's
├── local-agent-mode-sessions/<org>/<workspace>/...    #   "Cowork"/agent-mode feature — a different product
├── vm_bundles/, claude-code-vm/                       #   surface from regular claude.ai chat (see note below)
├── config.json, claude_desktop_config.json, Preferences, window-state.json, plan-usage-history.json, ...
└── (no *.sqlite / *.db files anywhere in the tree)
```

There is **no SQLite database** anywhere under the app support directory — Claude Desktop does not use SQLite for chat storage the way e.g. some other Electron chat apps do.

### IndexedDB (`https_claude.ai_0.indexeddb.leveldb`) — small, agent/skill-metadata flavored
Only ~1.1 MB total (152 keys in the compacted table). A structural scan of key/value tokens (filtered to short schema-like identifiers, not sentence content, to avoid capturing message text) surfaced things like:
`AskUserQues`, `agentsA`, `attachment`, `autoCompactThreshold`, `cache_creation_input_tokens`, `github__`, `mcp__github__`, `instruc[tions]`, `job_log`, `keybindings`, `Linear_`, `memoryFile`, `milestone`, `pipeline`, `queued_command`, `redirectedContext`, `FOR_SUBAGENTS_ONLY`, etc.

This reads as caching for the **Cowork / agent-mode** feature (skills, MCP tool definitions, job logs, agent instructions) rather than a durable archive of ordinary claude.ai chat turns. It's consistent with the separate `local-agent-mode-sessions/` and `claude-code-sessions/` directories found alongside it (see note below).

### Local Storage (`Local Storage/leveldb`) — larger, but UI/query-cache flavored
~31 MB across several `.ldb`/`.log` files. Structural token scan surfaced keys like:
`react-query-cache-ls`, `rq-cache-confirmed-account`, `epitaxy-tasks-store`, `branch-status-cache`, `pr-detected-cache`, `org-settings-cache`, `session-diff-stats-store`, `started_cowork_conversation`, `v2ChatWidth`.

This is dominated by **React Query cache** (`*-cache-ls`, `rq-cache-*`) and UI/view state (panel widths, feature caches for GitHub PR/branch status used by Cowork) — i.e., ephemeral, evictable client caches that mirror API responses for fast reload, not a purpose-built append-only chat log. No object-store or key name resembling a stable "conversations"/"messages" table was found.

### Important local/OS caveats
- **The app was running** and held an active OS-level lock (`LOCK` file, confirmed via `lsof`) on the IndexedDB LevelDB directory. Any external reader attempting to open these LevelDB folders while Claude Desktop is running will hit LevelDB's single-writer lock and fail (or require closing the app first) — a real operational obstacle for a background indexer.
- **Schema volatility**: these are Chromium `react-query` cache blobs and internal Electron/IDB structures tied to the current app/library version; Anthropic gives no compatibility guarantee for third parties reading them, and the schema can change on any app update.
- Net conclusion: **full conversation text is not reliably present as a stable local corpus.** What's cached locally is transient UI/query state and agent-mode metadata, gated behind a live-process file lock and an undocumented, frequently-changing schema — not a realistic target for a stable reader.

### Note: Claude Code sessions embedded in Claude Desktop are a different, separate surface
`claude-code-sessions/` and `local-agent-mode-sessions/` contain readable JSON files (`local_<uuid>.json`) — these are Claude Code CLI / Cowork "agent mode" run sessions launched from inside Claude Desktop (the same underlying format the sibling research ticket on Claude Code JSONL sessions is investigating), **not** regular claude.ai web-chat conversations. They should be treated as part of that other research thread, not this one.

---

## 2. The claude.ai data-export flow

Official docs (fetched 2026-08-08):
- https://support.claude.com/en/articles/9450526-how-can-i-export-my-claude-ai-data (Claude Help Center; `support.anthropic.com` now 301-redirects here)
- https://privacy.claude.com/en/articles/9450526-export-your-claude-data (Anthropic Privacy Center, same content)
- https://privacy.claude.com/en/articles/13346720-export-your-organization-s-data (Team/Enterprise org-level export, Primary Owner only)

Key facts from the official article:
- **How requested**: Manual only. Settings → Privacy → "Export data" button, in the web app or Claude Desktop. No mention of any API-based export trigger.
- **What's included**: "conversation data and the user data for your account" (the article doesn't spell out the exact zip/file names, but this is Anthropic's full personal-data export, commonly reported by third parties as a zip containing a `conversations.json` plus account/user metadata JSON).
- **Delivery**: Anthropic emails a download link to the account's registered email address once the export is generated ("There may be a small delay while the export is generated" — no committed SLA). The link **expires 24 hours after delivery**, and the user must be signed in to use it.
- **Automation**: None described or supported — it's a manual, click-through, human-in-the-loop flow (email delivery + signed-in download), not something designed to be polled or scripted.
- **Deletion caveat**: messages/files/projects deleted before the export are excluded — the export reflects current-state, not a full history including deletions.
- **Freshness implication for Floodlight**: this is fundamentally a **snapshot export**, requested by hand, delivered by email, with a short-lived link. It cannot serve as a live or near-real-time index source; at best it's a periodically-refreshed static corpus the user manually re-imports.

---

## 3. Sanctioned API? Terms-of-service boundary

- **No consumer API to list/read claude.ai conversations.** The public Claude Developer Platform API (`api.anthropic.com`, docs at platform.claude.com) is for building on top of Claude models (Messages API, batches, token counting, Models API) — it has no endpoint for reading a Free/Pro/Max/Team user's claude.ai chat history. It's a different product surface entirely (Commercial Terms, no relationship to a user's claude.ai account data).
- **Consumer Terms of Service** (govern Free/Pro/Max/Team claude.ai accounts) prohibit accessing the Services "through automated or non-human means, whether through a bot, script, or otherwise," except via an official API key or explicit Anthropic authorization, and separately restrict scraping. Anthropic has also publicly enforced this in 2026 against third-party tools/harnesses using consumer OAuth tokens outside sanctioned products.
- **The boundary Floodlight must not cross**: claude.ai's internal web app does call an undocumented private API (session-cookie authenticated) to load chat history in the browser/Electron UI. That endpoint is not published, not versioned for external consumers, and using it programmatically (scraping via session cookie replay) would violate the Consumer ToS's automated-access and scraping prohibitions. **This research explicitly does not attempt or recommend that path** — noting it only to draw the boundary clearly for the spec.

---

## Summary table

| Path | Live/fresh? | Full text available? | Sanctioned? | Verdict |
|---|---|---|---|---|
| Local LevelDB/IndexedDB read (Electron caches) | N/A — even if read, not reliably present | No — UI/query cache + agent-mode metadata, not a stable chat archive | Technically local-only, no ToS issue, but blocked by app-held file lock + undocumented/volatile schema | Not viable |
| Manual data export (`Settings → Privacy → Export data`) | No — manual, ad hoc, snapshot | Yes — this is the one place real conversation text appears in a structured, exportable form | Yes — first-party, sanctioned feature | **Viable as a periodic static import**, not live search |
| Consumer/Developer API | Would be live if it existed | N/A | N/A | Does not exist for this purpose |
| Scraping claude.ai's internal web API | Would be live | Yes | **No — violates Consumer ToS** (automated access + scraping bans) | Out of bounds, not recommended, not pursued |

## Recommendation for Floodlight's spec

State explicitly: **Floodlight indexes Claude Code JSONL session transcripts as its live local AI-chat source.** For claude.ai / Claude Desktop chat history, support an **optional manual import**: user runs Anthropic's official data export, drops the resulting `conversations.json` (from the exported zip) into a folder Floodlight watches, and it's indexed as a static, versioned corpus like any imported document — with a visible "last imported: <date>" marker so users understand it's not live. Do not build a LevelDB/IndexedDB reader against the Electron app's caches, and do not scrape claude.ai's internal API.
