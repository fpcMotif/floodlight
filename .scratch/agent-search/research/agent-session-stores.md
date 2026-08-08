# AI coding agent session stores — inventory (this machine, macOS, 2026-08-08)

Primary evidence: direct inspection of real files/databases under `martinfan`'s home directory (`fd`/`du`/`sqlite3`/`jq`/`python3`), plus, where local data was sparse, direct inspection of the **installed package source** (`~/.bun/install/global/node_modules/@google/gemini-cli/bundle/*.js`). Secondary evidence: official docs/repos, cited per section. No transcript text is reproduced below beyond field names and tiny elided structural samples.

---

## Summary table

| Agent | Store kind | Path pattern | Project association | Title/summary field | Scale on this machine |
|---|---|---|---|---|---|
| pi | JSONL, per-project dir | `~/.pi/agent/sessions/<slug>/<ISO-ts>_<uuid>.jsonl` | dir-slug = cwd, `/`→`-`, wrapped in leading/trailing `--` | none observed in sampled files (only `compaction.summary`) | 5,889 files, 79 MB |
| omp | JSONL, per-project dir + sibling artifact dir | `~/.omp/agent/sessions/<slug>/<ISO-ts>_<uuid>.jsonl` (+ same-named dir for externalized tool output) | dir-slug = cwd, same scheme as pi | `session.title`/`title_change` events, explicit | 399 files, 462 MB |
| crush | SQLite, per-project + global fallback | `<projectDir>/.crush/crush.db`; global `~/.crush/crush.db` | implicit: DB lives inside the project's own `.crush/` dir | `sessions.title` column | 4 DBs seen: 7+2+0+15 sessions; 9.1M/128K/128K/192K |
| codex | JSONL, date-sharded + cross-session index | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; archived under `~/.codex/archived_sessions/` | `session_meta.payload.cwd` | `~/.codex/session_index.jsonl` → `{id, thread_name, updated_at}` | 1,648 rollout files / 2.6 GB; 14 archived / 3.0 MB; index has 234 rows |
| Claude Code | JSONL, per-project dir + subagent subfolder | `~/.claude/projects/<slug>/<session-uuid>.jsonl` (+ `<session-uuid>/subagents/agent-<id>.jsonl` and `.meta.json`) | dir-slug = cwd, non-alphanumeric→`-` | `custom-title` event line (`customTitle`) | 3,365 jsonl files, 1.2 GB, 125 project dirs |
| amp | **Cloud-primary**; local = debug logs + tiny history only | Local: `~/.cache/amp/logs/threads/T-*.log` (JSON-RPC/event debug log); `~/.local/share/amp/history.jsonl` (prompt-input history only, not transcripts); `~/.amp/file-changes/T-*/` (per-tool-call file diffs) | thread lives server-side at ampcode.com; local cwd only in tool-lease events | thread_title events appear in the debug log but canonical title lives server-side | Local: `.amp` 3.9M, `.cache/amp` 12M (125 thread logs, but only content-bearing), `.local/share/amp` 160K |
| opencode | SQLite (Drizzle), single DB per channel | `~/.local/share/opencode/opencode.db` (active), plus separate `opencode-next.db` / `opencode-stable.db` for other channels | `session.project_id` → `project.worktree` (absolute dir) | `session.title` column | opencode.db: 5 sessions/234 messages/980 parts, 18 MB; opencode-next.db: 3 sessions, 5.1 MB; opencode-stable.db: 0 sessions, 192 KB |
| droid (Factory) | JSONL, per-project dir, sibling settings file | `~/.factory/sessions/<slug>/<session-uuid>.jsonl` + `<session-uuid>.settings.json` (+ `.bak`) | dir-slug = cwd, non-alphanumeric→`-` | `session_start.title` (+ `isSessionTitleManuallySet` flag) | 72 jsonl files, 35 MB |
| gemini (Gemini CLI) | JSONL-in-`.json`-named-file, per-project temp dir | `~/.gemini/tmp/<projectIdentifier>/chats/session-<uuid>.json` (append-only JSONL despite extension); subagents nested at `chats/<parentSessionId>/<agentId>.json(l)`; separate `~/.gemini/tmp/<id>/logs/session-<uuid>.jsonl` and `tool-outputs/session-<uuid>/` for externalized blobs | `projectIdentifier` = short id from a `ProjectRegistry` keyed by project root path (registry file `~/.gemini/config/projects.json`-style + `~/.gemini/history/<identifier>/.project_root`) | metadata record's `summary` field | **Empty on this machine** — see per-agent note. `~/.gemini/history/xtimelinefilter/` exists (registry marker only); `~/.gemini/tmp` has zero children |

---

## Per-agent detail

### 1. pi

- **Path**: `~/.pi/agent/sessions/<slug>/<ISO8601-with-dashes>_<uuid>.jsonl`. Slug is the absolute cwd with `/` replaced by `-`, wrapped in a leading and trailing `--` pair, e.g. `/Users/martinfan/nix-config` → `--Users-martinfan-nix-config--`. Ephemeral/tool-spawned cwds (temp dirs, `pi-runtime-*` scratch runs) get their own slug the same way, which is why most of the 5,889 files sit under noisy `--var-folders-...--` / `--tmp-...--` slugs rather than real project dirs.
- **Format**: JSONL, one JSON object per line, forming a **tree** via `id`/`parentId` (not a flat array) — this is the branching/compaction mechanism, not literal file forking.
  - Header line: `{"type":"session","version":3,"id":"<uuid>","timestamp":"...","cwd":"/abs/path"}`
  - `{"type":"message","id":"...","parentId":"...","timestamp":"...","message":{...}}` — `message.role` ∈ `assistant | toolResult | user`. Assistant messages carry `api`, `model`, `provider`, `stopReason`, `usage` (`input/output/cacheRead/cacheWrite/totalTokens/cost{...}`). `message.content` is a block array with block `type` ∈ `text | thinking | toolCall`; a `toolCall` block is `{type,id,name,arguments}`. `toolResult`-role messages carry `toolCallId`, `toolName`, `isError`, `details`.
  - `{"type":"model_change", provider, modelId}`, `{"type":"thinking_level_change", thinkingLevel}`, `{"type":"custom", customType, data}` (extension-defined events, e.g. an auto-update-checker event seen in the sample), `{"type":"compaction", firstKeptEntryId, summary, tokensBefore, usage, fromHook}` — the compaction event's `summary` is the closest thing to an auto-title, generated only when context gets compacted.
- **No explicit session title/summary line** was found in sampled files beyond the compaction summary — contrast with omp below.
- **Scale**: 5,889 `.jsonl` files, 79 MB total.
- **Write behavior**: append-only NDJSON stream; the parent-linked tree design (each new event just appends referencing a prior `id`) is inherently append-friendly, no rewrite evidence observed (file mtimes only move forward across a session).
- **Source**: this is Mario Zechner-style "pi coding agent" tooling — `earendil-works/pi` (`packages/coding-agent`), docs at `packages/coding-agent/docs/session-format.md` and `sessions.md` in that repo. https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md

### 2. omp

- **Path**: `~/.omp/agent/sessions/<slug>/<ISO8601-with-dashes>_<uuid>.jsonl`, same slug scheme as pi (cwd with `/`→`-`, wrapped in `--`). Alongside the `.jsonl` file, a **same-named directory** exists holding externalized artifacts from that session: numbered `<msgIndex>.bash.log` / `.bash-original.log` / `.eval.log` / `.shake.log` files (tool-output blobs kept out of the main JSONL to bound its size), plus in one observed case top-level `<SubagentName>.jsonl` + `.md` pairs — i.e. **subagent transcripts sit flat inside the parent session's artifact dir**, in the same JSONL schema as the parent.
- **Format**: essentially the same schema family as pi (near-identical field names strongly suggest omp is a fork/derivative of the pi coding-agent codebase), with richer metadata:
  - Header: `{"type":"session","version":3,"id":"<uuid>","timestamp":"...","cwd":"...","title":"...","titleSource":"auto"}` — **omp adds an explicit auto-generated title on the header line itself.**
  - A dedicated `{"type":"title","v":1,"title":"...","source":"auto","updatedAt":"...","pad":"..."}` line and `{"type":"title_change", title, source, previousTitle?, trigger?}` events fire whenever the title is (re)computed, e.g. `trigger:"replan"`.
  - `{"type":"message", id, parentId, timestamp, message:{role, content, ...}}`; roles seen: `assistant | toolResult | user`. Assistant messages add `contextSnapshot`, `duration`, `ttft`, `providerPayload`, `responseId` beyond pi's set. A `custom_message` type adds an `attribution` field (which extension/skill authored the message) and `display` hints.
  - Also observed: `thinking_level_change`, `model_change`, `service_tier_change` (all absent from the pi sample, but structurally the same idea).
- **Scale**: 399 `.jsonl` files, 462 MB (heavier per-file than pi, consistent with the externalized-artifact-dir pattern and denser subagent usage).
- **Write behavior**: append-only JSONL; large/verbose tool output is diverted into numbered sibling log files rather than inlined, keeping the transcript file itself append-friendly and smaller.
- **Source**: likely `can1357/oh-my-pi` ("Oh My Pi") — a `packages/coding-agent`-shaped fork/sibling of the pi toolkit (candidate repos found: `open-horizon-labs/oh-omp`, `can1357/oh-my-pi`; schema match with pi is the strongest local evidence). https://github.com/can1357/oh-my-pi

### 3. crush

- **Path**: SQLite file `.crush/crush.db` inside **each project's own directory** (e.g. `/Users/martinfan/devv/xtimelinefilter/.crush/crush.db`), plus a **global fallback** DB at `~/.crush/crush.db` (used e.g. from directories that don't have their own tracked `.crush/`). `~/.local/share/crush/` holds unrelated shared config (`crush.json`, `providers.json`, `projects.json`), not session data.
- **Format**: Go `goose`-migrated SQLite (`goose_db_version` table present). Schema (`sqlite3 crush.db .schema`):
  - `sessions(id, parent_session_id, title, message_count, prompt_tokens, completion_tokens, cost, updated_at, created_at, summary_message_id, todos)` — trigger-maintained `message_count`; `title` defaults to `"New Session"` until renamed/auto-titled.
  - `messages(id, session_id, role, parts, model, provider, created_at, updated_at, finished_at, is_summary_message)` — `role` ∈ `user | assistant | tool`; `parts` is a JSON array, each element `{"type":"text","data":{"text":"..."}}` (other part types exist for tool calls, not sampled here).
  - `files(id, session_id, path, content, version, ...)` — full-content snapshots of every file version touched in a session, keyed `(path, session_id, version)`.
  - `read_files(session_id, path, read_at)` — read-tracking.
  - Project association is **structural** (the DB's own directory location), not a column.
- **Scale**: sampled DBs — `xtimelinefilter/.crush/crush.db`: 7 sessions / 720 messages / 9.1 MB; `xediadownloader`: 2 sessions / 128 KB; `gosh-my-pi`: 0 sessions; global `~/.crush/crush.db`: 15 sessions / 192 KB.
- **Write behavior**: **WAL mode confirmed** (`PRAGMA journal_mode` → `wal`); `-shm`/`-wal` sidecar files present next to each `crush.db`. Row-level `UPDATE`/`INSERT` via SQLite triggers (auto `updated_at`, auto `message_count`), not append-only-file semantics.
- **Source**: `charmbracelet/crush` (Go, Bubble Tea TUI; SQLite via `sqlc`, migrations under `internal/db/migrations/`). Docs note the schema "isn't a public API and breaks on migrations." https://github.com/charmbracelet/crush · https://deepwiki.com/charmbracelet/crush/2.9-storage-and-database (as cross-referenced for opencode below; crush's own DeepWiki page: https://deepwiki.com/charmbracelet/crush)

### 4. codex

- **Path**: `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl` (date-sharded by session start date); older/cleared threads move to the flat `~/.codex/archived_sessions/rollout-<ts>-<uuid>.jsonl`. A **cross-session title index** lives at `~/.codex/session_index.jsonl`.
- **Format**: JSONL, one event per line, all sharing `{timestamp, type, payload}`:
  - `session_meta` (first line): `payload = {session_id, id, timestamp, cwd, originator, cli_version, source, thread_source, model_provider, base_instructions:{text}}`. On this machine `originator` was `"Codex Desktop"`, `cli_version` `0.146.0-alpha.9.2` — a heavily customized/plugin-extended Codex install (extra top-level stores: `memories_*.sqlite`, `goals_*.sqlite`, `logs_*.sqlite`, `state_*.sqlite`, `.codex-global-state.json`, none of which are core-Codex chat storage).
  - `turn_context`: `{approval_policy, approvals_reviewer, collaboration_mode, comp_hash, current_date, cwd, effort, model, multi_agent_version, permission_profile, personality, realtime_active, sandbox_policy, summary, timezone, turn_id, workspace_roots}`.
  - `response_item`: wraps a Responses-API item; `payload.type` ∈ `message | reasoning | function_call | function_call_output | custom_tool_call | custom_tool_call_output`. `message` payloads carry `role` (`user`/`assistant` via `input_text`/`output_text` content parts) plus `id`, `phase`, `internal_chat_message_metadata_passthrough`.
  - `event_msg`: UI-facing event stream; `payload.type` ∈ `agent_message | agent_reasoning | task_started | task_complete | token_count | user_message | web_search_end` (others exist upstream, e.g. tool-approval events, not present in this sample).
  - `world_state`: one line, environment/tool-availability snapshot.
- **Title metadata**: NOT in the rollout file — lives in the separate `~/.codex/session_index.jsonl`, one line per session: `{"id":"<uuid>","thread_name":"<auto-generated title>","updated_at":"<ISO>"}`. This is the file Codex Desktop reads for its session-picker list (per upstream issue discussion — Desktop currently sometimes rescans `sessions/`+`archived_sessions/` instead of trusting the index incrementally, a filed perf bug).
- **Scale**: 1,648 rollout `.jsonl` files / 2.6 GB under `sessions/`; 14 files / 3.0 MB under `archived_sessions/`; `session_index.jsonl` has 234 rows (i.e. far fewer indexed threads than raw rollout files — index entries appear to be created lazily/selectively, not 1:1).
- **Write behavior**: append-only rollout files (event-sourced turn log); files reported by upstream as created world-readable (mode 0644) — a filed security issue, not something observed to require fixing here.
- **Source**: `openai/codex` (open source). Rollout/session-index behavior confirmed against upstream issue/discussion threads: https://github.com/openai/codex/discussions/3827 · https://github.com/openai/codex/issues/22583 · https://github.com/openai/codex/issues/20864

### 5. Claude Code

- **Path**: `~/.claude/projects/<slug>/<session-uuid>.jsonl` — main transcript. `<slug>` = absolute cwd with every non-alphanumeric character replaced by `-` (e.g. `/Users/martinfan/devv/floodlight` → `-Users-martinfan-devv-floodlight`). Sibling directory `<slug>/<session-uuid>/subagents/` holds one `agent-<agentId>.jsonl` + `agent-<agentId>.meta.json` per Task-tool subagent spawned from that session.
- **Format**: JSONL, one object per line, chained by `parentUuid`/`uuid` (linked-list per branch; `isSidechain:true` distinguishes subagent-internal chains).
  - Common envelope fields on `user`/`assistant` lines: `cwd, entrypoint, gitBranch, isSidechain, message, parentUuid, promptId, sessionId, timestamp, type, userType, uuid, version`. Assistant lines add `attributionPlugin`, `attributionSkill`, `effort`, `requestId`.
  - `message.content` block `type` ∈ `text | thinking | tool_use` (tool results are their own `user`-role lines with `tool_result` content, per public write-ups; not separately re-verified here beyond the block-type tally).
  - Other line `type`s observed on this machine: `queue-operation` (queued-prompt bookkeeping), `attachment`, `mode` (interaction-mode changes), `system` (e.g. `subtype:"stop_hook_summary"` recording which stop-hooks ran and their durations), `last-prompt`.
  - `custom-title`: `{"type":"custom-title","customTitle":"...","sessionId":"..."}` — the session's display title (auto-generated or user-renamed); may repeat multiple times across the file, last one wins.
  - Subagent `.meta.json` sidecar: `{"agentType":"general-purpose","description":"...","toolUseId":"toolu_...","spawnDepth":1,"model":"sonnet"}`.
- **Scale**: 3,365 `.jsonl` files across 125 project directories, 1.2 GB total.
- **Write behavior**: append-only; resuming a session keeps appending to the same file (can span many days). No lockfiles observed.
- **Source**: internal format, undocumented by Anthropic beyond the SDK's session-storage guide (which documents the *interface*, not the on-disk schema): https://code.claude.com/docs/en/agent-sdk/session-storage . On-disk schema corroborated against independent reverse-engineering write-ups: https://www.adityabawankule.io/blog/claude-code-session-jsonl-format and https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b — both match what was found locally (slug scheme, parentUuid chain, `subagents/` sidecar, `isSidechain`).

### 6. amp

- **This is the outlier: Amp's canonical session store is server-side** (ampcode.com), not local. Confirmed via:
  - `amp --help` exposes `threads list/continue/search/share/export/rename/archive/delete` — all operate against synced server state, and `threads share`/`multiplayer` imply real-time server-mediated collaboration.
  - `~/.cache/amp/logs/threads/T-<id>.log`: a JSON-RPC/event debug log of the local **executor** talking to a remote **thread-client** transport over a persistent connection (`"Transport connection state changed"`, `"connected"`). Event `type`s include `client_append_user_msg`, `message_added`, `thread_title`, `delta`, `executor_tool_lease_ack`, `executor_git_diff_snapshot`, etc. — i.e. the full conversation *is* observable in this debug log, but it's an ephemeral, rotating debug artifact, not the source of truth (only 1 thread's log was retained locally out of many more threads visible via `amp threads list`).
  - `~/.local/share/amp/history.jsonl`: **not a transcript** — each line is `{"cwd","text"}`, i.e. prompt-input readline history only (118 lines on this machine).
  - `~/.local/share/amp/{session.json, secrets.json, device-id.json}`: auth/device identity, not chat data.
  - `~/.amp/file-changes/T-<threadId>/<toolCallId>.<uuid>`: per-tool-call file-diff artifacts (used for the file-change review UI), keyed by thread id — useful for correlating local file edits to a thread, but not a transcript store.
  - `~/.config/amp/settings.json`: `{"amp.dangerouslyAllowAll":true}` — unrelated permission config.
- **Scale (local only)**: `~/.amp` 3.9 MB (38 thread dirs of file-change artifacts); `~/.cache/amp` 12 MB (125 log files, mostly small connection logs, one 14,410-line full thread debug log); `~/.local/share/amp` 160 KB.
- **Write behavior**: local logs are append-only NDJSON; canonical thread state lives in a database on Sourcegraph's servers, kept in sync over a persistent JSON-RPC transport (reconnect/resume events visible in the logs).
- **Source**: https://ampcode.com/manual (confirms threads sync to ampcode.com and are accessible/shareable there); https://github.com/sourcegraph/amp-examples-and-guides

### 7. opencode

- **Path**: `~/.local/share/opencode/opencode.db` (the actively-written DB on this machine — most recent mtime, largest size), plus channel-pinned siblings `opencode-next.db` and `opencode-stable.db` (same schema, presumably populated by `opencode-ai@next` / `@stable` invocations rather than the default `opencode` binary).
- **Format**: SQLite via Drizzle ORM (`__drizzle_migrations`/`migration` tables present). Relevant tables:
  - `project(id, worktree, vcs, name, icon_url, icon_color, time_created, time_updated, time_initialized, sandboxes, commands, icon_url_override)` — `worktree` is the absolute project directory; a synthetic `project.id="global"`/`worktree="/"` row exists for out-of-project usage.
  - `project_directory(project_id, directory, type, strategy, time_created)` — extra directories associated with a project (monorepo/worktree support).
  - `workspace(id, type, name, branch, directory, extra, project_id, time_used)`.
  - `session(id, project_id, parent_id, slug, directory, title, version, share_url, summary_additions, summary_deletions, summary_files, summary_diffs, revert, permission, time_created, time_updated, time_compacting, time_archived, workspace_id, path, agent, model, cost, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write, metadata)` — very rich: `title` is a real column (auto-generated, e.g. `"New session - 2026-08-02T15:33:04.717Z"` when not yet titled, or a descriptive auto-title once generated); `model` stored as a JSON string `{"id":...,"providerID":...,"variant":...}`; `parent_id` supports session nesting/forking.
  - `message(id, session_id, time_created, time_updated, data)` — `data` is a JSON blob: `{agent, model, role, summary, time}` (role/agent/model duplicated from outer columns are not stored in JSON — `id`/`sessionID` inside the JSON are null because the outer table columns are authoritative).
  - `part(id, message_id, session_id, time_created, time_updated, data)` — one row per content block; `data.type` observed: `text, reasoning, tool, patch, step-start, step-finish`.
  - `session_share(session_id, id, secret, url, ...)` — public share links.
  - `session_message` / `session_input` — an additional (possibly legacy or event-stream-oriented) messaging table separate from `message`/`part`; not fully reconciled against `message`/`part` in this pass.
- **Scale**: `opencode.db`: 5 sessions, 234 messages, 980 parts, 18 MB; `opencode-next.db`: 3 sessions, 5.1 MB; `opencode-stable.db`: 0 sessions, 192 KB.
- **Write behavior**: **WAL mode confirmed** on all three DBs (`-wal`/`-shm` sidecars present); opencode.db's WAL file was 2.3 MB at inspection time (active writer).
- **Source**: `sst/opencode` (Go/TS; migrated from JSON-file to SQLite storage). https://github.com/sst/opencode · https://deepwiki.com/sst/opencode/2.9-storage-and-database

### 8. droid (Factory)

- **Path**: `~/.factory/sessions/<slug>/<session-uuid>.jsonl` + sibling `<session-uuid>.settings.json` (and rotated `.settings.json.bak`). `<slug>` = absolute cwd, non-alphanumeric→`-`, same scheme as Claude Code.
- **Format**: JSONL, one object per line, message tree via `id`/`parentId` (pi/omp-style):
  - `session_start` (first line): `{"type":"session_start","id":"<uuid>","title":"...","owner":"martinfan","version":2,"cwd":"...","hostId":"...","isSessionTitleManuallySet":bool,"sessionTitleAutoStage"?:"first_message", "callingSessionId"?, "callingToolUseId"?}` — **title is present from the very first line**, and subagent/worker sessions carry `callingSessionId`/`callingToolUseId` pointing at the parent session (subagent transcripts are **sibling files in the same project directory**, linked by these fields — not nested in a subfolder like Claude Code/Gemini CLI).
  - `message`: `{type:"message", id, parentId, timestamp, message:{role, content:[...]}}`; roles `user | assistant`; content block `type` ∈ `text | thinking | tool_use | tool_result | image`.
  - `agent_turn_outcome`: `{turnId, reason:"completed", resultKind:"text"}` — turn boundary marker.
  - `todo_state`, `compaction_state`: periodic snapshots of the todo list and compaction bookkeeping.
  - Sidecar `<uuid>.settings.json`: `model, reasoningEffort, interactionMode, autonomyLevel/Mode, tags` (subagent tag carries `callingSessionId`/`callingToolUseId`), `tokenUsage{inputTokens,outputTokens,cacheCreationTokens,cacheReadTokens,thinkingTokens,factoryCredits}`, `inclusiveTokenUsage`, `childInclusiveTokenUsageBySessionId`, `providerLock`/`apiProviderLock`.
- **Scale**: 72 `.jsonl` files, 35 MB.
- **Write behavior**: append-only JSONL for the transcript; the `.settings.json` sidecar is rewritten (not appended) as token counters/state change, with a rotating `.bak` copy kept — the one file in this store that is clearly rewrite-in-place rather than append-only.
- **Source**: `docs.factory.ai` (product docs cover CLI usage/slash-commands, not the on-disk JSONL schema, which was reverse-engineered here from primary evidence). https://docs.factory.ai/droid-cli/cli-reference

### 9. gemini (Gemini CLI)

- **This store was empty on this machine** — findings below are grounded in the **installed package's actual source** (`~/.bun/install/global/node_modules/@google/gemini-cli/bundle/*.js`, version `0.43.0-preview.1`, confirmed to be the real `@google/gemini-cli` package via its `package.json` and the `gemini.js` entrypoint's `GEMINI_CLI_HOME`/`~/.gemini` defaulting logic), cross-checked against the upstream repo.
- **Path** (per `Storage` class, `packages/core/src/config/storage.ts` equivalent in the bundle):
  - `getGlobalGeminiDir()` = `~/.gemini` (or `$GEMINI_CLI_HOME`).
  - `getGlobalTempDir()` = `~/.gemini/tmp`.
  - `getProjectTempDir()` = `~/.gemini/tmp/<projectIdentifier>`, where `projectIdentifier` is a short id assigned by a `ProjectRegistry` keyed off the absolute project root (not a raw hash in the visible path — a `getProjectHash()` sha256 helper exists but is used elsewhere, e.g. dedup/migration, not as the directory name itself).
  - Chat sessions: `getProjectTempDir()/chats/session-<uuid>.json` — **despite the `.json` extension this is actually append-only JSONL** (confirmed both by the reader, which does `readline` line-by-line `JSON.parse`, and by an upstream PR that explicitly migrated chat recording from whole-file JSON rewrites to streaming JSONL: "migrate chat recording to JSONL streaming", google-gemini/gemini-cli#23749).
  - Subagent sessions nest under the parent: `chats/<parentSessionId>/<agentId>.json(l)`.
  - Also under the project temp dir: `logs/session-<uuid>.jsonl` (separate structured/tool-call log), `tool-outputs/session-<uuid>/` (externalized large tool outputs, threshold `MAX_TOOL_OUTPUT_SIZE = 50 * 1024` bytes — same externalization pattern as omp), `<sessionId>/plans` (plan-mode artifacts), `memory/skills` (project memory cache).
  - Separate from chat state: `getHistoryDir()` = `~/.gemini/history/<projectIdentifier>/` — this is what's actually present on this machine (`~/.gemini/history/xtimelinefilter/.project_root` containing the literal project path). This directory is registry/prompt-history bookkeeping, not chat transcripts — its presence with an empty `tmp/` sibling indicates the project was registered (gemini was run in that directory) but no chat was ever recorded to disk, consistent with **exclusively headless/one-shot (`-p`) invocations** on this machine (the on-disk chat-recording code path also checks `isHeadlessMode`).
- **Format** (from `chatRecordingTypes.ts`/`chatRecordingService.ts` source, `SESSION_FILE_PREFIX = "session-"`, `MAX_HISTORY_MESSAGES = 50`):
  - A metadata record (first line, updatable via `$set` partial-update records): `{sessionId, projectHash, startTime, lastUpdated, summary, memoryScratchpad, directories, kind}` — **`summary` is the closest analog to a title**, generated over the course of the conversation.
  - Message records: `{id, timestamp, type, content, displayContent, thoughts?, tokens?, model?}` — `type` ∈ `user | gemini | info | warning | error` (role-equivalent field is `type`, not `role`).
  - `{"$rewindTo": "<messageId>"}` tombstone-style records implement the `/restore`/rewind (undo) feature by marking history truncation points **without ever rewriting the file** — an append-only design for what would otherwise require in-place edits.
- **Write behavior**: append-only JSONL (post-migration; older `@google/gemini-cli` versions did whole-file rewrite-on-every-message, per the linked PR/issue history — this machine's `0.43.0-preview.1` postdates that migration).
- **Source**: `google-gemini/gemini-cli`, `packages/core/src/services/chatRecordingService.ts` and `chatRecordingTypes.ts`. https://github.com/google-gemini/gemini-cli/pull/23749 (JSONL streaming migration) · https://github.com/google-gemini/gemini-cli/issues/15292 · https://deepwiki.com/google-gemini/gemini-cli/3.9-session-management

---

## Synthesis: normalized session model for an adapter seam

A common-denominator model an adapter layer should target:

```
Session {
  id: string                     // native session/thread id (uuid, snowflake-hex for omp, sqlite PK for crush/opencode)
  agent: "pi"|"omp"|"crush"|"codex"|"claude-code"|"amp"|"opencode"|"droid"|"gemini"
  title: string | null           // see per-agent title source below; null when never generated
  projectDir: string | null      // absolute cwd/worktree; null for amp (only inferable per-tool-call) and pre-registration gemini
  createdAt: timestamp
  updatedAt: timestamp
  parentSessionId: string | null // subagent/fork/branch lineage (pi/omp/droid: parentId chains within one file; Claude Code/Gemini: separate nested file; opencode/crush: parent_session_id/parent_id column)
  messages: [
    {
      role: "user"|"assistant"|"tool"|"system"   // normalize: pi/omp "toolResult"→tool, gemini "gemini"→assistant/"info|warning|error"→system, codex input_text/output_text→user/assistant
      text: string | null
      thinking: string | null      // pi/omp/droid/Claude Code/codex(reasoning) all have a distinct thinking/reasoning block; gemini has "thoughts"; crush/opencode fold it into parts with type reasoning
      toolUse: [{ id, name, arguments, result?, isError? }] | null
      timestamp: timestamp
    }
  ]
}
```

**Title/summary source per agent** (what an indexer should read for a cheap session-list view, before opening/parsing the full transcript):
- pi: none reliable — would need to derive from first user message or last `compaction.summary`.
- omp: `session.title` header field / latest `title_change` event.
- crush: `sessions.title` SQL column (SQL `SELECT`, no parsing needed).
- codex: `~/.codex/session_index.jsonl` → `thread_name` (cheap cross-session index, avoids opening rollout files at all — but only 234 of 1,648 rollout files are indexed, so a full listing still needs a fallback scan).
- Claude Code: last `custom-title` line's `customTitle` (requires scanning the file, or trusting a possible internal index this research didn't find one for).
- amp: not locally available at all — would require calling the Amp CLI/API (`amp threads list`) rather than reading local files.
- opencode: `session.title` SQL column.
- droid: `session_start.title` (first line of the file — cheapest of all JSONL-based agents).
- gemini: metadata record's `summary` field (first-line-ish, but mutated via `$set` records later in the stream, so a full-file scan is technically required for the *latest* value).

**Per-agent gaps against the normalized model**:
- **amp**: no local transcript at all by default — only a rotating debug log (not guaranteed retained) and cloud storage. An adapter would either need the Amp CLI/API as a data source, or accept amp as unindexable from local files alone (except recently-active threads that still have a debug log).
- **pi**: no title field; message-tree (not flat) requires a small graph walk to linearize; huge fan-out of ephemeral/scratch-cwd session dirs (temp-dir slugs) that a project-scoped search should filter out.
- **crush/opencode**: not file-based at all — needs a SQLite reader in the adapter, not a JSONL line-scanner; opencode has 3 separate DB files (channel-specific) that all need to be unioned; crush needs both the per-project `.crush/db` *and* the global fallback DB to get full coverage, and per-project DBs are scattered across arbitrary project directories rather than one root (would need a `fd -H -t d '^\.crush$'`-style sweep, not a single glob).
- **gemini**: project association is indirect (via a registry, not derivable from the tmp-dir name alone without also reading `~/.gemini/history/<id>/.project_root` or the registry file); this machine has essentially zero data to validate the schema against live records — schema confidence here rests on source-code inspection + upstream PR/issue corroboration, not a parsed real file.
- **droid**: subagent linkage is by convention (`callingSessionId` sibling files) rather than physical nesting, so reconstructing a session tree requires indexing all files in a project dir up front, not just opening one file.
- **codex**: `session_index.jsonl` is not authoritative/complete (only a subset of rollout files are indexed) and upstream has open bugs about it going stale vs. the raw `sessions/` tree — an adapter should treat the raw rollout files as ground truth and the index as a cache/hint only.
