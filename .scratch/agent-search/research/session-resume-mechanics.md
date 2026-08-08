# Session-resume mechanics for nine CLI agents (research findings)

Scope: for each of pi, omp, crush, codex, Claude Code, amp, opencode, droid, gemini —
the exact CLI incantation to resume a *specific* past session by id, what identifier
it needs, where that id lives in the on-disk session store, whether cwd must match,
and interactive-vs-non-interactive reattach flags. Plus: how a macOS app should spawn
Ghostty/Kitty/Terminal.app with that command. All commands below were read from
`--help`/subcommand `--help` output and source/docs; **none were executed to resume or
launch a session** (read-only investigation per ticket constraints).

## TL;DR resume matrix

| Agent | Resume-by-id command | Id source | cwd must match? | Non-interactive variant |
|---|---|---|---|---|
| **pi** | `pi --resume <path\|id>` (aliases: `-r`, `--session`) | filename UUID under `~/.pi/agent/sessions/<encoded-cwd>/` | Only if you pass a bare id (cross-project id triggers a fork-or-abort prompt); **full path bypasses the check entirely** | `-p/--print` combined with `--resume`; picks up model/thinking from session |
| **omp** | `omp --resume <path\|id>` (aliases: `-r`, `--session`) — same binary/codebase as pi | same as pi, under `~/.omp/agent/sessions/<encoded-cwd>/` | same as pi | same as pi |
| **crush** | `crush --session <id>` (alias `-s`) | `sessions.id` (UUID) in **per-project** SQLite `<project>/.crush/crush.db` | Yes — must run with `--cwd <project>` (or from that dir); the DB is per-project, not global | `crush run "<prompt>" --session <id>` for one-shot; interactive is default |
| **codex** | `codex resume <SESSION_ID>` (or `codex resume --last`, or bare `codex resume` for a picker) | `payload.id` UUID inside the `session_meta` line of the rollout `.jsonl`; file path itself is date-bucketed, not cwd-bucketed | No for exact UUID (works from anywhere); picker view *is* cwd-filtered unless `--all` is passed. `-C/--cd <dir>` sets the resumed agent's working root | `codex exec resume <SESSION_ID>` |
| **claude** (Claude Code) | `claude --resume <session-id>` (alias `-r`) | filename `<uuid>.jsonl` under `~/.claude/projects/<encoded-cwd>/`; `sessionId` field repeated in every line | No, as of CLI ≥ v2.1.223 — cross-directory lookup searches beyond cwd. Older bundled CLIs scope to cwd + git worktrees | `claude -p --resume <id>` (print/non-interactive); `--fork-session` to branch instead of continue |
| **amp** | `amp threads continue <threadId>` | Thread id `T-xxxxxxxx-...` — no meaningful local id→cwd store; threads live server-side on ampcode.com | No — threads aren't cwd-scoped at all; local disk only has a per-terminal "last thread" pointer and a log file named by thread id | `amp threads continue <threadId> -x "<prompt>" --stream-json` |
| **opencode** | `opencode --session <id>` (alias `-s`), or `opencode run --session <id> "<msg>"` | `session.id` (`ses_...`) in SQLite `~/.local/share/opencode/opencode.db`; `session.directory` column holds the absolute project path | Practically yes — resolve `directory` from the DB and launch with process cwd set there (`--dir <path>` flag also exists on `run`) | `opencode run --session <id> "<msg>"` |
| **droid** | `droid --resume <sessionId>` (alias `-r`) | filename `<uuid>.jsonl` under `~/.factory/sessions/<encoded-cwd>/`; `id`/`cwd` fields in the `session_start` header line | Directory-encoded like Claude Code; run with matching `--cwd` to be safe (no documented cross-project search) | `droid exec -s <sessionId> "<prompt>"` (exec mode always needs a prompt) |
| **gemini** | `gemini --resume <uuid>` (alias `-r`); also accepts `latest` or a numeric index from `--list-sessions` | Session dir hashed from project root: `~/.gemini/tmp/<project_hash>/chats/`; UUID is the persistent id, index is just a picker position | Yes — sessions are project-hash-scoped, so cwd must match the project the session was created in | No documented flag to resume + auto-execute a prompt non-interactively in one shot; use `-i/--prompt-interactive` after resuming, or accept the interactive drop-in |

## Gaps / where "resume by id" isn't a clean CLI feature

- **amp**: no local, cwd-indexed session store to speak of. `~/.local/share/amp/session.json` only remembers `lastThreadId` / `lastThreadByTerminal` (keyed by a terminal-instance id, e.g. `"ghostty:0x2c32a78e938ad317"`) for the *most recent* thread convenience feature — not a general id→directory index. `~/.cache/amp/logs/threads/T-<id>.log` exists but is a CLI activity log, not the canonical transcript (that's server-side). **Recommended fallback for Floodlight**: index whatever local thread ids/log files exist, but resume must hit the network (`amp threads continue <id>`) since Amp doesn't guarantee an offline-resumable local copy.
- **crush**: session storage is **per-project SQLite**, not the `~/.local/share/` global location the ticket assumed — actual layout is `<project-root>/.crush/crush.db`, discovered via `~/.local/share/crush/projects.json` (a `path → data_dir` map). Floodlight's indexer needs to walk `projects.json`, not a single global DB.
- **gemini**: `--resume` only takes `latest`, a numeric index, or a UUID — and only *within* the current project's hashed session dir. There's no cross-project id search; Floodlight must cd into the matching project dir before invoking `--resume <uuid>`, and there's no built-in non-interactive "resume + run one prompt + exit" combo (index-based UX is the safer default if the exact project hash mapping isn't precomputed).
- **pi / omp**: cross-project resume-by-bare-id shows a `Fork into current directory? [y/N]` prompt and **errors out under non-TTY** if declined/no answer — so a backgrounded/non-interactive launch must either (a) already be cd'd into the session's original cwd, or (b) pass the full `.jsonl` path (which is looked up and opened directly, no prompt, per `packages/coding-agent/src/main.ts` in the `gosh-my-pi` fork at `/Users/martinfan/gosh-my-pi`).
- **droid**: no documentation found (docs.factory.ai pages fetched were sparse) confirming whether resume searches beyond the cwd-encoded directory; treat as cwd-scoped like Claude Code's pre-2.1.223 behavior until proven otherwise.

## Per-agent detail

### pi / omp (`gosh-my-pi`, personal fork of `oh-my-pi`)

These are the user's own fork (`git@github.com:fpcMotif/gosh-my-pi.git`, upstream `can1357/oh-my-pi`), installed via Nix (`pi` at `/nix/store/.../pi-coding-agent-0.83.0/...`, `omp` at `/nix/store/.../oh-my-pi-17.2.4/...`, both symlinked into `/etc/profiles/per-user/martinfan/bin/`). No public hosted docs; the authoritative source is the repo itself, specifically:
`docs/session-operations-export-share-fork-resume.md` and `packages/coding-agent/src/main.ts` (`createSessionManager`), both in `/Users/martinfan/gosh-my-pi`.

- `--help` flags: `--resume, -r [value]`, `--session <path|id>` (parses identically to `--resume`/`-r` — same branch in `args.ts`), `--continue, -c`, `--session-id <id>` (exact, creates if missing), `--fork <path|id>`, `--session-dir <dir>`.
- Session store: `~/.pi/agent/sessions/<encoded-cwd>/<ISO-timestamp>_<uuidv7>.jsonl` (pi) and `~/.omp/agent/sessions/<encoded-cwd>/<ISO-timestamp>_<uuidv7>.jsonl` (omp). `<encoded-cwd>` replaces path separators with `-`.
- Id resolution logic (`main.ts:createSessionManager`, confirmed by reading source):
  - If the `--resume`/`--session` value contains `/`, `\`, or ends in `.jsonl`, it's opened directly via `SessionManager.open(path)` — **no cwd check at all**.
  - Otherwise it's treated as an id prefix, searched first in the current cwd's session dir, then (if no explicit `--session-dir`) globally via `listAll()`.
  - If a global match's stored `cwd` differs from the process's current cwd, the CLI prompts `Session found in different project ... Fork into current directory? [y/N]`; declining or running non-interactively throws `Session "<id>" is in another project (<cwd>).`
- **Practical guidance for Floodlight**: launch with the terminal cwd set to the session's original project directory AND pass the full `.jsonl` path (not just the bare id) — this is the only combination that is guaranteed prompt-free and cwd-correct, since tool execution inside pi/omp uses the process's actual cwd, not the session's stored `cwd` metadata.
- Reattach flags: no special "non-interactive resume" flag beyond combining `-p/--print` with `--resume <path>`.

### crush (`charmbracelet/crush`)

- `--help`: top-level `-s, --session <id>` ("Continue a previous session by ID"), `-C, --continue` (most recent), `-c, --cwd <dir>`; subcommand `crush session {list|show|delete|rename|last}`.
- Storage: **per-project SQLite**, not global. `~/.local/share/crush/projects.json` maps each project `path` to a `data_dir` (e.g. `/Users/martinfan/devv/xtimelinefilter/.crush`). The actual DB is `<data_dir>/crush.db`, table `sessions(id TEXT PRIMARY KEY, parent_session_id, title, ...)` — verified directly via `sqlite3 ~/.crush/crush.db ".schema sessions"`.
- To resume: `crush --cwd <project-path> --session <session-id>` (or just run from inside that directory) — cwd is load-bearing because it determines which project's `.crush/crush.db` is opened.
- Non-interactive: `crush run "<prompt>" --session <id> --cwd <path>`.

### codex (OpenAI Codex CLI)

- `codex resume [SESSION_ID] [PROMPT]` — from `codex resume --help`: "Session id (UUID) or session name. UUIDs take precedence if it parses. If omitted, use `--last`". Flags: `--last` (skip picker, most recent), `--all` (disable cwd filtering, show CWD column in picker), `-C/--cd <DIR>` (working root for the resumed agent), `--include-non-interactive`.
- Also: `codex fork [SESSION_ID]` (same resolution, but branches into a new session).
- Storage: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<uuid>.jsonl` — **date-bucketed, not cwd-bucketed**. The id and originating cwd live inside the file's first line: `{"type":"session_meta","payload":{"id":"<uuid>","cwd":"<abs-path>",...}}` (verified by reading a rollout file directly).
- cwd behavior: the *picker* (`codex resume` with no id) filters candidates to the current cwd by default; `--all` removes that filter. Resuming by **exact UUID** does not require `--all` and works regardless of process cwd (per `openai/codex` issue #20165 and local testing pattern), since it's a direct id lookup across the date-bucketed tree, not a cwd-scoped listing.
- Non-interactive: `codex exec resume <SESSION_ID>` (confirmed via `codex exec --help`: `resume` is a listed subcommand — "Resume a previous session by id or pick the most recent with --last").
- Docs: official CLI docs live behind `https://developers.openai.com/codex/cli` (redirects to `https://learn.chatgpt.com/docs/codex/cli`), which only high-level-describes "Return to a saved chat" and defers to `codex resume --help` for flags — `--help` output is the most precise source here.

### claude (Claude Code)

- `claude --resume [value]` (alias `-r`): "Resume a conversation by session ID, or open interactive picker with optional search term". `claude --continue`/`-c`: most recent in current directory. `--fork-session`: when resuming, mint a new session id instead of reusing the original. `--session-id <uuid>`: force a specific id for a *new* session.
- Storage: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` (or under `$CLAUDE_CONFIG_DIR/projects/...` if that env var is set). `<encoded-cwd>` replaces every non-alphanumeric character in the absolute cwd with `-` (e.g. `/Users/me/proj` → `-Users-me-proj`). The uuid also appears as the `sessionId` field on every JSONL line (verified in a floodlight worktree session file). Source: [Claude Code docs — Work with sessions](https://code.claude.com/docs/en/agent-sdk/sessions).
- cwd requirement: **as of CLI ≥ v2.1.223, `--resume <id>` searches beyond the current project directory** to find the id — no cd needed. Older bundled CLIs (pre-2.1.223) scope the lookup to the current project dir and its git worktrees only. Floodlight should assume the newer, unscoped behavior but treat "must cd to the original dir" as the safe fallback if resume ever reports "not found."
- Non-interactive: `claude -p --resume <id> "<prompt>"` (`-p/--print`, with `--output-format stream-json` etc. for structured output). `--no-session-persistence` disables saving entirely (only relevant to fresh sessions, not resume).

### amp (Sourcegraph Amp)

- `amp threads continue [threads...]` (alias `t c`/`c`): "Continue an existing thread by resuming the conversation. Each thread can be a thread URL or ID." `--last`: continue the last thread for the current mode directly (no picker). Bare `amp threads continue` (no id) opens an interactive picker.
- Also: `amp last` (alias for continuing the very last thread), `amp threads list`, `amp threads search`.
- Id format: `T-<uuid>` (e.g. `T-019fc16d-436d-759f-bbdd-7e7b86213c2b`), referenceable as a bare id or full `https://ampcode.com/threads/T-...` URL.
- Storage/cwd: **threads are server-side** (synced to ampcode.com); there is no cwd-scoped local transcript store. Locally, `~/.local/share/amp/session.json` only tracks `lastThreadId`, `lastExecuteThreadId`, and `lastThreadByTerminal` (keyed by a terminal-instance identifier, observed as `"ghostty:0x2c32a78e938ad317"` on this machine) — a convenience pointer, not an index Floodlight can search by directory. `~/.cache/amp/logs/threads/T-<id>.log` exists per-thread but is a CLI log, not the transcript.
- Non-interactive: `amp threads continue <threadId> -x "<prompt>"` (alias `--execute`), with `--stream-json` for structured output.
- Docs: [Amp Owner's Manual](https://ampcode.com/manual), [amp-examples-and-guides CLI README](https://github.com/sourcegraph/amp-examples-and-guides/blob/main/guides/cli/README.md).

### opencode

- Top-level `--session <id>` (alias `-s`) / `opencode run --session <id> "<msg>"`; `--continue`/`-c` for most recent; `--fork` to branch when continuing.
- Storage: SQLite at `~/.local/share/opencode/opencode.db` (also `opencode-stable.db`, `opencode-next.db` per channel). Schema (read via `sqlite3 ... .schema`): `session(id TEXT PRIMARY KEY, project_id, directory, title, ...)`, `project(id TEXT PRIMARY KEY, worktree, ...)`, `project_directory(project_id, directory, ...)`. Session ids look like `ses_03dfa4375ffe...`. The `session.directory` column stores the absolute project path directly — no path-encoding needed, just `SELECT directory FROM session WHERE id = ?`.
- cwd requirement: not strictly enforced by the CLI the way Claude Code's directory-encoded storage is, but correctness requires launching with process cwd (or the `--dir <path>` flag on `run`) set to the session's `directory` value, since opencode's tools operate relative to the running process's cwd.
- Non-interactive: `opencode run --session <id> "<msg>"` (`--format json` for structured output).
- Docs: official docs at `https://open-code.ai/en/docs/cli`; also `opencode session --help` locally (only exposes `list`/`delete` subcommands — resume itself is a top-level flag, not a `session` subcommand).

### droid (Factory CLI)

- `droid --resume [sessionId]` (alias `-r`): "Resume a session (defaults to last modified)". `droid --fork <sessionId>`: fork and resume. `droid --cwd <path>`: working directory.
- Storage: `~/.factory/sessions/<encoded-cwd>/<uuid>.jsonl` + matching `<uuid>.settings.json` (model, autonomy, token usage). The `session_start` header line inside the `.jsonl` carries both `"id"` and `"cwd"` (verified directly: `{"type":"session_start","id":"7873bfb4-...","cwd":"/Users/martinfan/devv/hott-book",...}`). `<encoded-cwd>` is dash-encoded the same way as Claude Code/pi/omp.
- Also indexed at `~/.factory/cache/session-discovery-index.json` and searchable via `droid search|find "<query>"` (message/document/tool-result full-text search across local sessions).
- Non-interactive: `droid exec -s <sessionId> "<prompt>"` (alias `--session-id`; exec mode always requires a prompt argument — there's no bare "attach and wait" non-interactive mode). `droid exec --fork <id> "<prompt>"` to branch instead.
- cwd requirement: no official doc confirms cross-directory search (docs.factory.ai pages fetched were thin); the on-disk layout mirrors Claude Code's cwd-encoded-directory pattern, so treat it as cwd-scoped and launch from `--cwd <original-dir>` to be safe.
- Docs: [docs.factory.ai/droid-cli/cli-reference](https://docs.factory.ai/droid-cli/cli-reference) (confirms `-r/--resume`, `droid exec -s <id> "continue"` pattern); deeper storage details came from direct filesystem inspection, not docs.

### gemini (Google Gemini CLI)

- `--resume, -r <value>`: "Resume a previous session. Use `latest` for most recent or index number (e.g. `--resume 5`)" — **and** a full UUID per official docs (the local `--help` text undersells this; docs confirm UUID acceptance). `--list-sessions`: list available sessions for the current project and exit. `--delete-session <index>`.
- Storage: `~/.gemini/tmp/<project_hash>/chats/`, where `<project_hash>` is derived from the project's root directory — confirmed structurally via `~/.gemini/config/projects/*.json` (id/name/updatedAt records) though no active chat files were present on this machine to inspect directly (`~/.gemini/tmp` was empty at scan time). Docs: [geminicli.com/docs/cli/session-management](https://geminicli.com/docs/cli/session-management/).
- cwd requirement: **yes, strictly** — sessions are project-hash-scoped, so `--resume <uuid>` only finds sessions whose hash matches the *current* project root. Floodlight must cd into the original project directory before invoking `--resume`.
- Non-interactive: no dedicated "resume then run one prompt and exit" flag was found; `-i/--prompt-interactive` executes a prompt and *then* drops into interactive mode, but doesn't combine with `--resume` per documented examples. Treat gemini resume as interactive-only for Floodlight's purposes.

---

## How Floodlight should launch a resumed session in Ghostty / Kitty / Terminal.app

### Ghostty

Ghostty's `-e`/`--command` do not work when double-clicking the `.app`, because macOS launches the bundle without forwarding argv the way `open --args` does. The confirmed working pattern (from `ghostty-org/ghostty` GitHub discussions) is:

```sh
open -na Ghostty --args \
  --working-directory="<project-dir>" \
  -e <absolute-path-to-agent> --resume <session-id-or-path>
```

- `-n` forces a new process instance (needed so a second resume doesn't just focus an existing window); pair with `--quit-after-last-window-closed=true` in Ghostty's config so stray instances don't pile up in the Dock.
- `--working-directory=<path>` sets the shell's cwd before the command runs — load-bearing for every cwd-scoped agent above (pi, omp, crush, droid, gemini).
- `-e <cmd> <args...>` must be the *last* thing in `--args`; everything after `-e` is passed through verbatim as argv, not re-parsed by a shell — so no globbing/quoting surprises, but also no `&&` chaining without wrapping in `sh -c '...'`.

### Kitty

Two options depending on whether a kitty process is already running:

```sh
# Cold start — no kitty instance running yet
kitty --directory "<project-dir>" -e <absolute-path-to-agent> --resume <session-id>

# Warm — reuse an existing kitty via remote control (requires `allow_remote_control yes`
# and `listen_on unix:/tmp/kitty.sock`-style socket in kitty.conf)
kitten @ launch --type=os-window --cwd="<project-dir>" \
  <absolute-path-to-agent> --resume <session-id>
```

`--type=os-window` is required — the bare `kitten @ launch` default opens a *window* (split) inside the existing OS window/tab, not a new top-level window.

### Generic fallback: AppleScript → Terminal.app

For a portable fallback that doesn't assume Ghostty or Kitty are installed:

```applescript
tell application "Terminal"
  activate
  do script "cd " & quoted form of "<project-dir>" & " && <absolute-path-to-agent> --resume <session-id>"
end tell
```

`do script` with no target always opens a **new** window; targeting `window 1` reuses the frontmost one instead. Prefer the new-window form for resume actions so an in-progress unrelated session in the frontmost window isn't disturbed. Invoke from Swift via `NSAppleScript` or `osascript -e '...'`.

### GUI-app PATH/env caveat (all three launch paths)

macOS GUI apps (including a Floodlight `.app` launched from Spotlight/Dock/Finder) are started by `launchd`, not by a login shell — they do **not** source `~/.zshrc`, `~/.zprofile`, or any Nix per-user profile activation script. This matters directly here because the nine agent binaries are scattered across:

- `/etc/profiles/per-user/martinfan/bin/` (pi, omp, crush, codex, amp, opencode, droid — the Nix per-user profile)
- `/Users/martinfan/.local/bin/` (claude)
- `/Users/martinfan/.bun/bin/` (gemini)

None of these are on the default GUI-process `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin` plus whatever `/etc/paths` and `/etc/paths.d/*` contribute). Two ways to make the resume commands above resolve reliably:

1. **Best**: Floodlight resolves and stores each agent's **absolute binary path** (as listed above) at index time and always execs that full path — sidesteps the PATH problem entirely regardless of launch mechanism.
2. **Fallback**: if Floodlight ever shells out via a login shell instead (`zsh -lic '<cmd>'`), that *does* re-source `/etc/zprofile`, `/etc/zshrc`, and the user's own `~/.zshrc`/`~/.zprofile`, which is where a Nix/nix-darwin per-user profile's PATH additions normally get sourced from — but this repo's `/etc/zshrc` and `/etc/zprofile` were checked and contain no explicit per-user PATH additions, meaning the Nix profile PATH entries visible in this session's Bash tool come from a different mechanism (likely `nix-darwin`'s system Zsh integration or the user's own dotfiles) that a GUI app's `zsh -l` invocation may or may not replicate exactly. **Absolute paths remain the reliable choice.**
3. Ghostty's `-e` and Kitty's `-e` both exec argv directly without going through a shell at all when given as separate `--args`/trailing tokens — another reason to pass the full binary path rather than a bare command name.

## Sources

- Claude Code: [Work with sessions](https://code.claude.com/docs/en/agent-sdk/sessions)
- Codex: `codex --help`, `codex resume --help`, `codex exec --help` (local); [openai/codex issue #20165](https://github.com/openai/codex/issues/20165) (cwd-filtering nuance); `https://developers.openai.com/codex/cli` → redirects to `https://learn.chatgpt.com/docs/codex/cli`
- Droid: [docs.factory.ai/droid-cli/cli-reference](https://docs.factory.ai/droid-cli/cli-reference); `droid --help`, `droid exec --help` (local)
- Gemini CLI: [geminicli.com/docs/cli/session-management](https://geminicli.com/docs/cli/session-management/); `gemini --help` (local)
- opencode: [open-code.ai/en/docs/cli](https://open-code.ai/en/docs/cli); `opencode --help`, `opencode session --help`, `opencode run --help` (local); local SQLite schema inspection
- crush: `crush --help`, `crush session --help` (local); local `projects.json`/SQLite inspection; [charmbracelet/crush](https://github.com/charmbracelet/crush)
- amp: [Amp Owner's Manual](https://ampcode.com/manual); [amp-examples-and-guides CLI README](https://github.com/sourcegraph/amp-examples-and-guides/blob/main/guides/cli/README.md); `amp --help`, `amp threads continue --help`, `amp last --help` (local); local `session.json`/log inspection
- pi/omp: `/Users/martinfan/gosh-my-pi` (local repo, `git@github.com:fpcMotif/gosh-my-pi.git`, upstream `can1357/oh-my-pi`) — `docs/session-operations-export-share-fork-resume.md`, `packages/coding-agent/src/main.ts`, `packages/coding-agent/src/session/session-manager.ts`, `packages/coding-agent/src/cli/args.ts`
- Ghostty: [ghostty-org/ghostty discussion #9221](https://github.com/ghostty-org/ghostty/discussions/9221), [discussion #6053](https://github.com/ghostty-org/ghostty/discussions/6053)
- Kitty: [kitty launch docs](https://sw.kovidgoyal.net/kitty/launch/), [kitty remote control docs](https://sw.kovidgoyal.net/kitty/remote-control/)
- Terminal.app AppleScript: [Scripting OS X — macOS shell command to create a new Terminal Window](https://scriptingosx.com/2020/03/macos-shell-command-to-create-a-new-terminal-window/)
- GUI-app PATH caveat: [nix-darwin issue #1080](https://github.com/LnL7/nix-darwin/issues/1080), [Bounga — Set system-wide PATH for macOS GUI apps](https://www.bounga.org/tips/2020/04/07/instructs-mac-os-gui-apps-about-path-environment-variable/)
