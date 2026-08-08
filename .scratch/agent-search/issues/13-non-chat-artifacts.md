# Non-chat agent artifacts in the index

Type: grilling
Status: open

## Question

The store inventory (ticket 01) surfaced agent artifacts beyond chat sessions: pi todos (`~/.pi/todos/*.md` + events), pi/omp worktrees, omp terminal-session logs, codex's `session_index.jsonl`, installed skills/extensions. Which of these, if any, join the search index — and as what result kind?

- Are any of them daily-workflow finds ("that todo pi wrote", "the worktree for X"), or is chat-sessions-only the right v1 scope?
- If included: do they ride the same adapter seam and normalized model, or is that model chat-shaped and these need their own kinds?

Resolve via /grilling; the answer scopes the index section of the spec.
