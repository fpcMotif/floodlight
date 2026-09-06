# CLAUDE.md — Floodlight

Swift 6.4 / SwiftUI macOS app (Spotlight alternative), SwiftPM only. Full
project conventions live in the README and `docs/adr/`.

## Tooling rules

- **Do not reach for Python unless nothing else fits.** File edits go through
  the editor tools or `sed`; searches through `rg`/`fd`/ast-grep; data munging
  through `jq`. Python is a last resort for a task where it is clearly the
  best tool (an image/contrast computation, a one-off multi-file transform).
- **When Python is justified, run it through `uv`** — `uv run script.py`, or
  `uvx <tool>` for a packaged CLI — never bare `python3`, never `pip`.
  Inline-dependency scripts (`# /// script` header) are preferred over any
  virtualenv setup.
- JS/TS in `docs/` uses `bun` / `bunx`, never npm or npx.

## Quality gates

```sh
make check   # format, lint, ast-grep rules, architecture, build, dead code — same as CI
make test    # swift test
make format  # fix formatting; never hand-format
```

Every change must leave `make check` and `make test` green. Never commit a
throwaway test harness (e.g. render dumps) — SwiftLint's function-length and
identifier rules reject them, on purpose.

## Design work

- Clipboard board metrics live in `FloodlightMetrics` — never a literal at a
  call site. Text hierarchy uses `.primary` / `.secondary`; `.tertiary` is for
  placeholders and disabled text only.
- The Floodlight Figma file is `k8C7ZtvsLyPaOlSCo3Zn45`; the canvas cannot
  render SF Pro, so Figma text uses Inter as the stand-in.
