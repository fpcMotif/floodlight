# Session resume mechanics per agent

Type: research
Status: resolved

## Question

Enter on a session hit resumes that session in its agent. For each covered agent (pi, omp, crush, codex, Claude Code, amp, opencode, droid, gemini), establish from `--help`/docs:

- The exact incantation to resume a *specific* past session (`claude --resume <sessionId>`, `codex resume <id>`, pi/omp/crush/amp/opencode/droid/gemini equivalents), and whether resuming by id is supported at all.
- What identifier the command needs and where that id lives in the session store (ticket 01's schemas).
- Whether it must run with cwd = the session's original project directory.
- How a macOS app should launch it: which terminal app (Ghostty/Kitty per the user's setup), how to pass cwd and command, GUI-vs-shell env differences.

Deliver: a resume matrix (agent → command, id source, cwd requirement, caveats) plus the gaps where resume isn't supported and what the fallback should be (open transcript view instead). Findings → [research/session-resume-mechanics.md](../research/session-resume-mechanics.md).

## Answer

Resume matrix: **pi/omp** — `<bin> --resume <path|id>`; the path form bypasses cwd checks entirely (verified from source), bare-id cross-project resume prompts/fails non-interactively; store `~/.{pi,omp}/agent/sessions/<encoded-cwd>/<ts>_<uuidv7>.jsonl`. **crush** — `crush --session <id> --cwd <dir>`; store is **per-project** SQLite (`<project>/.crush/crush.db`, mapped via `~/.local/share/crush/projects.json`), not the assumed global location. **codex** — `codex resume <uuid>` (exact id works from any cwd; `--all` only affects the picker); store is date-bucketed `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` with `cwd`/`id` in the header; non-interactive: `codex exec resume <id>`. **claude** — `claude --resume <id>`; store `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`; cwd-unscoped since CLI ≥2.1.223. **droid** — `droid --resume <id>`; store `~/.factory/sessions/<encoded-cwd>/<uuid>.jsonl`; non-interactive: `droid exec -s <id> "<prompt>"`. **opencode** — `opencode --session <id>`; SQLite `~/.local/share/opencode/opencode.db`, `session.directory` gives the absolute path directly. **gemini** — `--resume <uuid>|latest|index`; strictly project-hash-scoped (`~/.gemini/tmp/<hash>/chats/`); no non-interactive resume+run flag found.

**Gaps:** amp has no cwd-indexed local store — threads are server-side; only a "last thread per terminal" pointer exists locally, so resume must hit the network (fallback: transcript view / open amp in the project dir).

**Terminal launch:** `open -na Ghostty --args --working-directory=<dir> -e <bin> --resume <id>`, or `kitty --directory <dir> -e ...` / `kitten @ launch --type=os-window`; AppleScript `Terminal.app` `do script` as the generic fallback. Always exec **absolute binary paths** — GUI apps don't inherit the Nix per-user-profile or `~/.local/bin`/`~/.bun/bin` PATH.

Full findings: [research/session-resume-mechanics.md](../research/session-resume-mechanics.md)
