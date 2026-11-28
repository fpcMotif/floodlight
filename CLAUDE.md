# Nanospot

Nanospot is a Zig 0.17 and nanoui macOS launcher (`app/`) over a memory-mapped Zig file index (`core/`). `GLOSSARY.md` defines the domain terms, and `docs/adr/` records the architectural decisions. The nanoui source that the build pins is unpacked in `app/zig-pkg/<hash>/`, with the hash from `app/build.zig.zon`.

## Tooling rules

- **Use purpose-built tools before Python.** Edit files with editor tools, search with `rg`, `fd`, or `ast-grep`, and reshape JSON with `jq`. Reserve Python for jobs where nothing else fits, such as PNG byte filtering in `scripts/build-app-icon.sh`.
- **Run Python through `uv`.** Use `uv run script.py` with an inline `# /// script` header, or `uvx <tool>` for a packaged CLI. Do not call `python3` or `pip` directly, and do not create a virtualenv.
- **Run JavaScript and TypeScript with Bun.** The site in `docs/` uses `bun` and `bunx`, never `npm` or `npx`.

## Quality gates

```sh
make install-zig  # fetch pinned Zig 0.17.0 into .tools/, once
make install      # build release bundle, replace /Applications/Nanospot.app whole, verify signature
make check        # format check, core unit/cross-build/bench, app unit/bench/bundle/snapshot
make test         # same core + app verification suite
make format       # zig fmt across core/ and app/
make docs         # build the Astro documentation site with bun
```

Every change must leave `make check` green. `make test-nanoui` runs `zig build bench --release` in `app/` and prints `NANOSPOT_BENCH` latency lines. `make bench-nanoui-memory` checks the idle and retained memory budgets (`NANOSPOT_MEMORY`).

## Issue gates

- **Reachable gate.** When writing an issue, set a gate that changes inside that issue's scope can meet. A cause that another open issue owns stays out of the gate.
- **Foreign cause.** When the measurements blame a cause that another open issue owns, post the numbers on that issue, report this gate as blocked, and stop.

## Comments

A comment says **why** because the code already says what. `///` states the contract: invariants, preconditions, units, ownership, and thread rules. `//` states the reason: constraints, measurements, and subtle bugs avoided. Neither repeats the operation on the next line.

## Design work

- **Keep layout metrics in token tables.** Shared panel metrics live in `app/src/chrome.zig` (`metrics`, `space`, `type_size`, `fill`), and board metrics live in `app/src/board.zig` (`board_metrics`). Do not put raw layout literals at call sites.
- **Keep the three-level text hierarchy.** Use primary theme text for titles and `chrome.tone(theme).secondary` for supporting labels. Reserve `.tertiary` for placeholders, disabled text, and quiet symbols.
