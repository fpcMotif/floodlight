# Agent session stores and schemas

Type: research
Status: resolved

## Question

For each of the nine covered agents — pi, omp, crush, codex, Claude Code, amp, opencode, droid, gemini — establish against this machine's real stores plus primary docs:

- Where sessions live (exact paths; global vs per-project).
- Storage format: JSONL line schema (line types, roles, tool calls, nesting) or SQLite schema (tables, columns).
- What metadata exists per session: title/summary, project directory, timestamps, model, message count.
- Corpus scale on this machine (file counts, total size) and write behavior (append-only JSONL? rewritten? WAL SQLite?) — this drives incremental indexing.

Known starting points: pi `~/.pi/agent/sessions/<proj>/*.jsonl`; omp `~/.omp/agent/sessions/<proj>/*.jsonl`; codex `~/.codex/sessions/YYYY/MM/DD/*.jsonl`; Claude Code `~/.claude/projects/<proj>/*.jsonl`; crush `~/.local/share/crush` + per-project `.crush`; opencode `~/.local/share/opencode/opencode-*.db`; amp/droid (`~/.factory`)/gemini (`~/.gemini`) unverified.

Deliver: a per-agent inventory table plus the common-denominator session model a per-agent adapter seam must normalize to (id, title, project, mtime, messages[role, text, tool-use]). Findings → [research/agent-session-stores.md](../research/agent-session-stores.md).

## Answer

Inventoried all nine stores via direct filesystem/DB inspection (plus installed-package source for gemini, which had zero local data): **pi** and **omp** are per-project JSONL trees (`id`/`parentId` chains) under `~/.pi(.omp)/agent/sessions/<cwd-slug>/`; omp adds explicit title events and externalizes tool output to sibling log files. **codex** uses date-sharded rollout JSONL (`~/.codex/sessions/YYYY/MM/DD/`) plus a lightweight cross-session title index (`session_index.jsonl`). **Claude Code** mirrors this (`~/.claude/projects/<slug>/<uuid>.jsonl`) with subagents nested in a `subagents/` subfolder and titles via `custom-title` events. **droid** (Factory) is JSONL with the title in the very first line and subagent linkage via sibling files (`callingSessionId`). **gemini** CLI's `ChatRecordingService` writes append-only JSONL (`.json`-named) to `~/.gemini/tmp/<projectId>/chats/`, but this machine's install has never persisted one (likely headless-only usage) — schema confirmed from installed source plus upstream PRs. **crush** and **opencode** are SQLite (Drizzle/goose), each with real `sessions.title` columns — crush per-project (`.crush/crush.db`) plus a global fallback, opencode as 1–3 channel DBs. **amp** is the outlier: canonical storage is server-side (ampcode.com); locally only a rotating debug log and prompt history, no real transcript store.

**Recommended normalized model:** `{id, agent, title, projectDir, createdAt, updatedAt, parentSessionId, messages:[{role, text, thinking, toolUse[], timestamp}]}`, with the title sourced per-agent (SQL column for crush/opencode, dedicated index/event for codex/omp/droid/gemini, full-scan-derived for pi/Claude Code, unavailable locally for amp).

Cross-reference from ticket 03: Cowork-launched Claude Code runs write JSONL under `~/Library/Application Support/Claude/claude-code-sessions/` (and `local-agent-mode-sessions/`) — the Claude Code adapter should treat these as additional roots.

Full findings: [research/agent-session-stores.md](../research/agent-session-stores.md)
