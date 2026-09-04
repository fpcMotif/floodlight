# Mac verification plan — #62 text/code file previews

Written on a Windows machine with no Swift toolchain; nothing below has been run. Run it on a Mac
before merging.

## Automated

```sh
make format && make check && swift test --filter FileTextPreviewTests
swift test
```

`make format` / `make check` catch formatting and lint/architecture-gate regressions (100-column
wrap, trailing commas, no force-unwrap in Sources, no new `public`, Periphery dead-code). The
filtered run isolates the rewritten suite; the full `swift test` catches any other suite that
touched `FileTextPreview`, `FileTextPreviewCache`, or `ClipboardInspectorPane` (grep confirmed
`SearchViewRenderingTests.swift` does not reference either, but the full run is the real check).

## Manual — 6 steps

1. **Copy a JSON path from Terminal** (`echo -n /path/to/some.json | pbcopy`, or select the path
   text and Cmd+C). Open Floodlight's Clipboard mode, select the entry.
   Expected: the inspector shows the JSON body as numbered, monospaced code lines within ~1
   frame — no blank/metadata-only flash that never recovers. A "Preview truncated" footer only
   appears if the file exceeds 64 KB or 200 lines.

2. **Copy a `.py` file from Finder (⌘C)**, select it in Clipboard mode.
   Expected: same numbered-code rendering as step 1, sourced from a native file-paste entry
   (`kind: .file`) rather than a copied path string — the two entry kinds must look identical for
   the same file.

3. **Copy a large `.log` file** (multi-MB, plain text). Select it.
   Expected: a loading placeholder (rounded gray rect + small spinner) appears immediately, then
   resolves to the first ~64 KB of wrapped, non-monospaced prose (readable-text path, not code),
   with a "Preview truncated" footer. No hang, no crash, no infinite spinner.

4. **Copy a `.txt` file containing Chinese text** near the 64 KB boundary (or any large `.txt`
   with multibyte characters throughout). Select it.
   Expected: every visible line is a complete, correctly-decoded line — no mangled trailing
   character, no mojibake, no `nil`-preview fallback to metadata-only. This is the multibyte
   byte-truncation fix; a build predating it would show a blank/metadata-only pane here for
   large enough files.

5. **Copy a `.md` file that lives somewhere Floodlight lacks Full Disk Access to** (e.g. inside
   another app's sandboxed container, or a path under `~/Library` guarded by TCC). Select it.
   Expected: metadata-only fallback — name, path, source, size, copy time — with no text/code
   preview block and no crash. This exercises the permission-denied path (`FileHandle` open
   failing), not a `try!`/force-unwrap trap.

6. **Rapid arrow-key scanning**: with 10+ mixed entries (JSON, Markdown, plain text, images,
   native file pastes) in the list, hold or repeatedly tap the down-arrow key to change the
   selection faster than each preview can load.
   Expected: the inspector always ends up showing the *currently selected* entry's preview, never
   a stale one from a previous selection that resolved late. No flicker-then-wrong-content, no
   crash. This exercises `.task(id:)` cancellation — the tri-state `LoadState` must ignore a
   superseded load rather than publish it.
