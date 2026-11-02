# Parity fixtures

One language-neutral fixture set that every Floodlight frontend runs through its own test runner (#112). A frontend is a full port when it passes all three.

| File | What it checks |
|---|---|
| `search.json` | A file tree and app folder, then per query: the ranked head of the result list, the Top Hit, chip counts, the web row; and search mode transitions |
| `clipboard.json` | Captures fed in order: what is stored (kind, content, detail, title, subtitle) or why it is skipped; ages and counts; list order, pinning, search and pruning |
| `board.json` | Key sequences on the clipboard board and the action each key asks for; the actions menu per entry |

Each file's `about` field says how to feed it. Expected values are what the Swift app shows; where a value comes from the Zig core's ranking, it is the core's, since every frontend searches through it.

Runners: `frontends/mygo/internal/parity` (Go).
