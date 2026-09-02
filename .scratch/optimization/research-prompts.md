# Research prompts

Each block is a self-contained prompt for an AI research assistant in web-research mode. Paste one at a time. Each names the finding IDs it unblocks (see [`README.md`](README.md)). Context every prompt assumes: macOS 14 and newer, Swift 6.4 with strict concurrency, SwiftUI + AppKit, SQLite3 with FTS5, and the fff file-search engine (Rust crate `fff-search` 0.10.5/0.10.6) linked as a static XCFramework through fff-swift 0.2.1.


# Search speed

## Search speed: algorithmic

None needed for this section — every open question here is answerable by reading the Floodlight/FFFKit source and running the described benchmarks on a Mac; nothing depends on external API behavior, undocumented OS semantics, or third-party library internals that aren't already visible in the vendored dependency.

If the maintainer wants one piece of external confirmation, this is optional and low-priority:

```
Title: OSAllocatedUnfairLock priority-inversion behavior on macOS 14+ (bears on F17)
Unblocks: F17

On macOS 14+ (Sonoma and later), using Swift 6.4's `OSAllocatedUnfairLock` (a wrapper
around os_unfair_lock): does the underlying os_unfair_lock primitive perform priority
donation / priority inheritance when a low-priority thread holds the lock and a
higher-priority thread (e.g. main-actor-adjacent work) blocks on it? Or does "unfair"
in os_unfair_lock refer only to the absence of FIFO wakeup ordering, with no priority
donation at all (unlike a mutex that inherits priority)?

Context: reviewing a code change that hoists a lock's critical section shorter
(SystemCatalog.swift in a Swift Package Manager app) to reduce worst-case hold time
under contention between a background actor-isolated refresh and a foreground search.//

Answer form: 2-4 sentences citing Apple's os_unfair_lock documentation or WWDC/kernel
source, stating definitively whether priority donation occurs, so the code comment
explaining "why we shortened the lock" is technically accurate rather than assuming
either behavior.
```

## Search speed: allocation and data layout

None needed for this section. Every open question in the input findings (e.g., whether `Set.contains` on an empty set skips hashing, whether `NumberFormatter.string(from:)` is safe for concurrent reads) was either resolved by direct code reading, downgraded to "unverifiable from this repo, treat as a minor caveat," or made moot because the corrected recommendation avoids the code path in question (e.g., F33's shared-`NumberFormatter` idea is dropped in favor of not sharing it). None of these blocks a go/no-go decision — they only affect the last few percent of an already-low-impact estimate. If the maintainer wants to chase the one dangling question anyway:

```
Title: Swift stdlib Set.contains fast path on empty sets (unblocks: F21)

On macOS 14+ with Swift 6.4 (Apple's standard library, not a third-party
collection), does `Set<String>.contains(_:)` skip computing the hash of the
argument when the set is empty (count == 0)? I'm trying to determine whether
an unconditional `blockedIDs.contains(id)` check against an empty
`Set<String>`, called ~a few hundred times per keystroke with `id` being an
80-byte path string, costs a SipHash computation each time or is a true O(1)
no-hash fast path in the current release stdlib. Cite the actual
_NativeSet/_HashTable implementation (swift/stdlib/public/core/Set.swift or
HashTable.swift on the current release branch) rather than general
Swift-performance blog posts. Answer as: yes/no + the specific code path
(function name, approximate line) that proves it, plus which Swift version
introduced that behavior if it changed historically.
```

## Search speed: concurrency, scheduling, cancellation

None needed for this section. Every finding here was resolved by reading the repository's own source (Swift 6.4 concurrency semantics under `NonisolatedNonsendingByDefault`, actor isolation, `Task.sleep`/cancellation behavior, AsyncStream/continuation semantics, and SQLite/FFFKit call patterns) and cross-checking two independent skeptic reviews against that source. No external API behavior, undocumented library internals, or macOS version-specific facts were left in question — FFFKit 0.2.1's public surface used here (`search`, `searchFiles`, `searchDirectories`, `searchContent`, `progress`) is fully exercised and observable in the existing call sites, and the one open question about FFFKit internals (whether it persists its index between launches, and whether it exposes a scan-completion callback instead of polling) is speculative/nice-to-know rather than blocking any proposal above — the polling-based `waitForScanCompletion` fix (a bounded deadline) works regardless of the answer. If the maintainer wants to pursue it anyway:

```
Title: FFFKit 0.2.1 index persistence and scan-completion API
Unblocks: F45 (secondary — not required to implement the proposed deadline fix)

I maintain a macOS 14+ app (Floodlight) using Swift 6.4 and the Swift package
FFFKit (fff-swift) version 0.2.1 as a fuzzy file finder / indexer. My code
wraps it in Sources/FloodlightEngine/Search/FFFIndex.swift, calling
`fff_create_instance_with(..., enableHomeDirectoryScanning: true)` and then
polling `index.progress()` in a loop (checking `isScanning`) to detect when
the initial home-directory scan completes, since I found no async
completion callback in the public API I'm using.

Two questions:
1. Does FFFKit 0.2.1 persist its scan index to disk between app launches
   (e.g. an on-disk cache keyed by directory mtime/fingerprint), such that
   a full home-directory scan only happens on first run or after a cache
   invalidation? Or does every process launch re-scan from scratch?
2. Does FFFKit 0.2.1 expose any completion notification for the initial
   scan (a callback, a Combine/AsyncSequence publisher, a Notification)
   instead of requiring callers to poll `progress()` on an interval?

Answer format: cite the specific FFFKit/fff-swift 0.2.1 public API
(function/type names) that answers each question, or state clearly that
no such API exists in that version if that's the case. Do not guess based
on how similar indexers typically work — I need to know what this specific
version actually exposes.
```


# Cold start

## Cold start

```text
FFFKit index persistence and home-directory scanning semantics — unblocks F62
Context: macOS 14+, Swift 6.4, using the Swift package FFFKit (fff-swift) version 0.2.1 as a binary/source dependency via `fff_create_instance_with` and a `FffCreateOptions` C-ish struct with fields including `enable_home_dir_scanning`, `enable_content_indexing`, `include_binary_files`, `watch`, `cache_budget_max_files`, `cache_budget_max_bytes`, `cache_budget_max_file_size`, `frecency_db_path`, `history_db_path`, and a `base_path`.
Questions:
1. Does FFFKit 0.2.1 persist its file/content index to disk across process restarts? If yes, where (a database file path derived from an option, an implicit cache directory, or only in-memory)? Is a distinct "index database path" option required, separate from `frecency_db_path`/`history_db_path`, or is persistence controlled by `enable_mmap_cache` or a similar flag?
2. When `enable_home_dir_scanning = true` is set alongside a `base_path` that is already a subdirectory of the user's home directory (e.g. `~/Downloads`), what exactly gets scanned — does it widen the scan to the entire home directory tree, or does it only affect handling of symlinks/junctions that point outside `base_path`?
3. What does `enable_content_indexing = true` combined with `include_binary_files = true` actually do at index-build time versus query time — does it eagerly read and index file contents for every discovered file during the initial scan, or is content indexing itself lazy/incremental, with `fff_live_grep` doing on-demand reads regardless of this flag?
4. Does `fff_restart_index(handle, path)` (the only rescan primitive found in the wrapper) support changing scan options (content indexing, binary files) without a full index rebuild, or does any restart always trigger a full re-scan?
Answer form: For each question, state the answer, cite the FFFKit/fff-swift source file and line or the published documentation/changelog for 0.2.1, and note if the information is not publicly available (in which case recommend instrumenting via the debug log environment variables `FLOODLIGHT_FFF_LOG`/`FLOODLIGHT_FFF_LOG_LEVEL` instead of guessing).
```

```text
SMAppService synchronous XPC cost on macOS 14+ — unblocks F59
Context: macOS 14+ (Sonoma/Sequoia/Tahoe), Swift 6.4, using `SMAppService.mainApp.status` (a synchronous property) and `SMAppService.mainApp.register()` (a synchronous throwing call) from `ServiceManagement`, called on the main thread during `NSApplicationDelegate.applicationDidFinishLaunching` for a login-item helper-less app (register self, not a separate login helper).
Questions:
1. What is the typical wall-clock cost of `SMAppService.status` and `SMAppService.register()` as synchronous main-thread calls, on a warm system versus immediately after boot (before `smd`/`ServiceManagement` daemon is fully warmed)? Cite any Apple documentation, WWDC session, or measured community reports.
2. Is there a supported way to call `SMAppService` status/register off the main thread or asynchronously (e.g. does it internally already dispatch, or must the call site wrap it in a Task/background queue itself)?
3. Are there known cases where `SMAppService.register()` throws or fails silently for unsigned/ad-hoc-signed builds, or apps not launched from `/Applications`, that would make an "enable on first run, remember success" pattern retry forever for developer builds?
Answer form: bullet-point findings with citations (Apple docs preferred), plus a one-line recommendation on whether to move the call off the main thread and/or defer it after first panel presentation.
```


# Responsiveness

## Responsiveness: UI and main thread

None needed for this section — every finding here is resolved by reading Floodlight's own code and by on-device Instruments/xctrace measurement, not by external research. All the mechanisms in question (SwiftUI `@Observable` invalidation, `NSCache`, `DateFormatter`, `QLThumbnailGenerator`, `NSWorkspace`, `ImageIO`) are well-documented Apple APIs already used correctly elsewhere in this same codebase (e.g. `FileIconCache.swift`, `FileThumbnailCache.swift`) — the fixes are ports of existing in-repo patterns, not open design questions.

If the maintainer wants one confirmatory check before investing in the F72 rewrite, this is optional:

```
Title: ImageIO thumbnail generation from raw pasteboard PNG/TIFF Data on macOS 14+
Finding IDs unblocked: F72

Context: A macOS 14+ app (Swift 6.4, SwiftPM, no third-party imaging deps) currently
generates a 128x128 thumbnail from clipboard image data by constructing an
NSBitmapImageRep(data:) from a full-resolution PNG/TIFF (potentially 4000x3000+ px,
up to 15 MB), drawing it into an offscreen NSGraphicsContext at 128x128, and
PNG-encoding the result — all synchronously on the main thread, triggered by a
0.5s polling timer on the pasteboard.

Question: What is the correct, current (macOS 14/15/26) ImageIO-based replacement
that avoids decoding the full-resolution image at all when only a small thumbnail
is needed? Specifically:
1. Exact CGImageSourceCreateWithData / CGImageSourceCreateThumbnailAtIndex call
   with kCGImageSourceCreateThumbnailFromImageAlways and
   kCGImageSourceThumbnailMaxPixelSize options, for PNG and TIFF input Data.
2. Is this API documented thread-safe for calling off the main actor
   (e.g. from a Swift 6 @concurrent nonisolated function)?
3. Any macOS-version-specific gotchas (e.g. HEIC/TIFF multi-page handling,
   color-profile handling) that would change visible thumbnail output versus
   the current NSBitmapImageRep + NSGraphicsContext approach.

Answer format: a short code snippet (Swift) plus a 3-5 line list of any behavioral
differences from the NSBitmapImageRep approach that a code reviewer should check for
in a before/after screenshot diff.
```

## Responsiveness: clipboard runtime

```
Title: Pasteboard type ordering and TIFF-vs-text precedence on macOS 14-26
Unblocks: F91

I'm working on a macOS 14+ Swift 6.4 app (uses the FFFKit/fff-swift 0.2.1 fuzzy-finder library, unrelated to this question) that captures the system pasteboard (NSPasteboard.general) via polling. I need to decide, at capture time, whether a given pasteboard change should be recorded as an image or as text, when BOTH a TIFF/PNG representation and a plain-text (public.utf8-plain-text) or RTF representation are present simultaneously.

Questions:
1. On macOS 14 through the current release (26), does NSPasteboard.types (or NSPasteboardItem.types) return types in an order that reliably reflects the declaring application's preference (richest/most-preferred representation first)? Cite Apple documentation or WWDC sessions if this is documented, or explain if it is explicitly undocumented/unreliable.
2. For common productivity apps — Apple Numbers, Microsoft Excel, Apple Pages, Microsoft Word, Apple Keynote — when a user copies a cell range or a formatted text selection, do these apps typically declare a rendered TIFF/PNG image on the pasteboard ALONGSIDE plain text or RTF? Is this behavior consistent across recent versions, or has it changed in recent macOS/Office versions?
3. Is there a more reliable heuristic than type ordering to distinguish "this pasteboard change is fundamentally an image copy" (screenshot, image editor, browser image copy) from "this is a text/table copy that happens to also carry a rendered preview image"? For example: presence of `com.apple.screencapture` type as a strong signal of image intent; or NSPasteboardItem-level introspection.

Answer format: a short technical summary (under 300 words) with citations, plus a recommended decision rule (pseudocode acceptable) for "prefer text vs prefer image when both are present," calibrated against the app list above.
```

```
Title: Requirements for posting a synthetic Cmd-V keystroke from a non-sandboxed macOS app
Unblocks: F95

I'm building a non-sandboxed (no App Sandbox entitlement, no com.apple.security.app-sandbox) macOS 14+ Swift 6.4 menu-bar/panel utility app that wants to, after writing content to NSPasteboard.general and reactivating a previously-frontmost application via NSRunningApplication.activate(options:), post a synthetic Cmd-V (paste) keystroke into that now-frontmost app using CGEvent.

Questions:
1. On macOS 14 through 26, does posting a CGEvent keyDown/keyUp for kVK_ANSI_V with the .maskCommand flag via CGEvent(keyboardEventSource:virtualKey:keyDown:) and posting to .cghidEventTap require Accessibility permission (AXIsProcessTrusted / "Accessibility" in System Settings > Privacy & Security), Input Monitoring permission, or both? Are the requirements different for .cghidEventTap versus .cgSessionEventTap versus .cgAnnotatedSessionEventTap?
2. After calling NSRunningApplication.activate(options: [.activateIgnoringOtherApps]) (or the current non-deprecated equivalent) on a target app, is there a race condition where a CGEvent posted immediately afterward can be delivered to the wrong app (the previously-frontmost utility panel) rather than the newly-activated target? What is the recommended way to wait for the activation to complete — NSWorkspace.didActivateApplicationNotification, polling NSWorkspace.shared.frontmostApplication, or a fixed delay — and what delay (if any) is commonly needed in practice?
3. Is AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true]) still the correct/current API to prompt for Accessibility permission on recent macOS versions, and does granting it also implicitly grant CGEvent-posting rights, or is a separate Input Monitoring grant needed for that specifically?

Answer format: a short technical summary (under 350 words) covering all three questions with macOS-version-specific caveats where they exist, citing Apple documentation/WWDC/developer forums, plus a minimal safe implementation sketch in Swift (activate -> wait -> post).
```

```
Title: Do modern macOS paste targets require a TIFF pasteboard representation, or is PNG sufficient?
Unblocks: F96

I'm deciding whether a macOS clipboard-manager app can safely stop writing a `public.tiff` representation to NSPasteboard when restoring a previously-copied image, and write only `public.png` instead (an NSImage/CGImage-backed representation still means AppKit can synthesize other representations lazily on request, per NSPasteboard's promise mechanism, but I want to confirm real-world consumer behavior).

Questions:
1. As of macOS 14-26, do any of the following common paste targets require a `public.tiff` representation to be present at paste time, rejecting or degrading when only `public.png` is offered: Preview.app, Pages, Keynote, Mail.app, Slack (desktop), Figma (desktop or web via Safari/Chrome), Microsoft Word, Microsoft PowerPoint?
2. When an app writes only `public.png` to the pasteboard via `NSPasteboard.setData(_:forType:)` (not via `writeObjects` with a lazy-promise NSImage), does AppKit or the receiving app itself synthesize a TIFF fallback automatically, or is the receiving app responsible for accepting whatever type is offered?
3. Is there a documented list (Apple HIG, pasteboard programming guide, or community consensus) of "safe minimum" pasteboard types to write when restoring an image, that maximizes compatibility across today's common macOS apps?

Answer format: a short answer (under 250 words) per app/target where known, noting anything unverified, plus a one-line recommendation: "PNG-only is safe" / "PNG-only risks compatibility with X" / "write both."
```


# Richer text

## Richer text

```text title="Pasteboard flavour fallback behaviour (unblocks F99)"
Platform: macOS 14 through 15 (Sonoma/Sequoia), Swift 6.4, AppKit (NSPasteboard/NSPasteboardItem).
Question: When an app writes an NSPasteboard item that contains ONLY rich flavours — e.g. public.rtf and/or public.html — with no public.utf8-plain-text representation, does NSPasteboard.string(forType: .string) perform automatic UTI-based conversion and synthesize plain text, or does it return nil? Is the answer different for .rtf vs public.html vs .rtfd? Does NSAttributedString(pasteboard:) / readObjects(forClasses: [NSAttributedString.self]) behave differently (i.e. does IT synthesize a flattened string even when .string does not)?
Cite Apple documentation and/or WWDC sessions on NSPasteboard promised types and UTI conversion where available; note any version-specific behavior changes between macOS 14 and 15.
Answer format: a short yes/no per pasteboard-reading API (string(forType:), readObjects(forClasses:[NSAttributedString.self])) with the supporting citation, plus one sentence on whether a capture path that only calls .string(forType: .string) can silently drop an entire copy operation when the source app publishes no plain-text flavour.
```

None needed for any other finding in this section — every other opportunity was resolved by reading the repository's own code (Sources/Floodlight, Sources/FloodlightEngine, Tests/) rather than external API behavior.


# Clipboard history

## Clipboard history management

```
Title: Password manager pasteboard concealment flags on macOS 14+ (unblocks F120)
Findings: F120

On macOS 14 through the current release (26), which desktop password managers mark clipboard items they write with `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, or `com.apple.is-sensitive` on the pasteboard, and which do not? Specifically check: Bitwarden desktop app AND its Safari/Chrome browser extension, 1Password 7/8 desktop app and browser extension, KeePassXC, Dashlane desktop and extension, LastPass desktop and extension, Proton Pass, Apple's own Keychain Access / iCloud Keychain fill. For each, state (a) whether the native desktop app marks copies, (b) whether the browser extension's copy-to-clipboard action marks copies (this is the common real-world path since users usually copy passwords from a browser extension, not the standalone app), and (c) which macOS APIs or documentation source your answer. Also confirm: does `NSPasteboard` on macOS 14+ still support these UTI-based concealment markers, or has anything changed (e.g. Sequoia/Sonoma pasteboard privacy changes)? Answer as a table: app | native app marks? | browser extension marks? | source/citation. This determines whether Floodlight's clipboard-history feature needs an app-bundle-ID exclusion seed list (works only for native-app copies) versus a different mitigation for browser-extension copies.
```

```
Title: SQLite secure_delete and FTS5 shadow-table coverage (unblocks F118)
Findings: F118

For SQLite as embedded via the system libsqlite3 on macOS 14+ (Swift 6.4 project, no bundled SQLite, using the C API directly via a Swift wrapper), does `PRAGMA secure_delete = ON` set on a connection automatically zero freed pages in FTS5 shadow tables (specifically the `_data`, `_idx`, `_content`, `_docsize`, `_config` tables SQLite creates for a `CREATE VIRTUAL TABLE ... USING fts5(...)` with external-content mode, i.e. `content=clipboard_entries`), or do those shadow tables need `secure_delete` set independently, or do they require a separate mechanism (e.g. `INSERT INTO fts5_table(fts5_table, rank) VALUES('secure-delete', 1)` or similar fts5 special command) to avoid leaving deleted text fragments in the trigram/token index after a row delete? Also: does `PRAGMA auto_vacuum = INCREMENTAL` interact with fts5 shadow tables in any special way, or can `PRAGMA incremental_vacuum` be called on the same connection right after a DELETE that cascades via `AFTER DELETE` triggers into the fts5 virtual table? Cite the SQLite documentation (sqlite.org fts5.html and pragma.html) directly rather than inferring. Answer should state definitively whether an app needs anything beyond `PRAGMA secure_delete = ON` on the connection to guarantee deleted clipboard text isn't recoverable from the fts5 index.
```

## Clipboard power-user convenience

None needed for this section. All open questions are resolvable by reading the codebase or by direct manual testing on the target Mac (see the checklist above) — none require external/web research. The two `researchNeeded` items surfaced by the findings are narrow enough to fold into manual verification rather than needing a research assistant:

```text
Title: macOS field-editor default key bindings for Control-N/Control-P (unblocks F130)
Finding IDs: F130

Context: Swift 6.4, SwiftUI + AppKit app targeting macOS 14+ (specify the exact deployment target from Package.swift if picking this up), using a single-line NSTextField as a Spotlight-style search field. The field currently has a custom NSTextViewDelegate `doCommandBy:` hook (Coordinator.control(_:textView:doCommandBy:)) that maps only insertNewline/insertNewlineIgnoringFieldEditor/cancelOperation/insertTab/insertBacktab/deleteBackward-on-empty; everything else (including moveUp:/moveDown:) currently falls through unhandled, and a test in Tests/FloodlightTests/SearchFieldKeymapTests.swift explicitly locks that fallthrough behavior for moveUp:/moveDown:.

Question: On macOS 14 through the current release (26), does NSTextView's/NSTextField's field editor apply the standard Cocoa text-system key-binding table (the one that maps Control-N to moveDown: and Control-P to moveUp: in a multi-line NSTextView, following historical Emacs-style bindings) to a *single-line* field editor specifically, or does the single-line field editor suppress/ignore vertical-movement selectors because there is nothing to move to? Also: does the presence of a custom DefaultKeyBinding.dict on the user's machine, or a user's own Text/Key Bindings preference pane customization, change this — i.e., is this binding guaranteed-present-by-default or something that varies per-machine?

Answer format: A short, sourced yes/no per macOS version bucket (14, 15, 26) with citation to Apple's Cocoa Text System / Key-Value Bindings documentation or WWDC material, plus one sentence on whether shipping this feature could be silently inert on any supported OS version or user configuration.
```

```text
Title: RegisterEventHotKey failure behavior when a shortcut is already claimed by another app (unblocks F131)
Finding IDs: F131

Context: Swift 6.4, macOS 14+ target, using the Carbon HIToolbox `RegisterEventHotKey` API (via `EventHotKeyRef`/`EventHotKeyID`) for a global keyboard shortcut in a menu-bar/panel utility app — same mechanism Alfred/Raycast-style launchers use. The app already has one working registration (Space-based combos) and is adding a second, user-configurable one (candidate default: Shift-Command-V), which collides with "Paste and Match Style" in many apps (Xcode, Pages, etc.) when that app is frontmost vs. when it is a true system-wide/background hotkey.

Question: When `RegisterEventHotKey` is called for a key combination that is already registered system-wide by another running application (not merely a per-app menu shortcut), does the call (a) return a nonzero OSStatus/error immediately, letting the caller detect the conflict and fall back to a different binding, or (b) return success but the installed event handler never fires because the OS delivers the event to the earlier registrant first? Does the answer differ between macOS 14, 15, and 26? Is there a documented or empirically reliable way for a Swift app to detect "this hotkey is already claimed by someone else" before or after registration, short of asking the user to test it manually?

Answer format: A short sourced answer per OS version bucket, plus a recommended detection/fallback strategy (code-shape is fine, no need for a full implementation) suitable for a `start(preferred:)`-style API that already has a "try, and fall back on failure" path for its first hotkey.
```


# Beyond the five

## Beyond the five: build, testing, hygiene, docs

None needed for this section. Every finding here was resolved by reading the repository directly (SwiftLint/Periphery config semantics, GitHub Actions defaults, git plumbing, SQLite pragmas) — nothing depends on external library behavior that isn't already pinned and inspectable in-tree. The one open question flagged by the original findings (F155's Periphery/index-store behavior on a missing path) is answered by direct experiment on an Intel Mac, not by web research, and is listed in the Mac todo above instead.

## Beyond the five: memory, energy, indexing

## Research: fff-c cache_budget_* and enable_mmap_cache semantics (unblocks F171)

```
Context: Floodlight is a macOS 14+ app (Swift 6.4) that embeds fff-swift 0.2.1 (FFFKit), a Rust-backed fuzzy file finder, via its C ABI (fff-c). The Swift wrapper (Sources/FloodlightEngine/Search/FFFIndex.swift) constructs a `FffCreateOptions` struct and unconditionally sets:
  options.enable_mmap_cache = true
  options.cache_budget_max_files = 0
  options.cache_budget_max_bytes = 0
  options.cache_budget_max_file_size = 0
for two separate FFF instances (a real file index and a small "application marker" index).

Question: In fff-swift / fff-c version 0.2.1's C ABI (the `FffCreateOptions` struct and `fff_create_instance_with`/`fff_create_instance3` entry points, defined in the crate `fff-c`, likely at `crates/fff-c/src/lib.rs` in the fff monorepo), what does a value of 0 mean for `cache_budget_max_files`, `cache_budget_max_bytes`, and `cache_budget_max_file_size`? Specifically: (a) does 0 mean "unlimited/unbounded", "disabled/no cache", or "let the engine auto-size based on available memory"? (b) Does `enable_mmap_cache = true` retain the memory-mapped content cache for the lifetime of the FFF instance, or only for the duration of a single search call? (c) Is there a recommended non-zero budget for a background/agent-style macOS app that should not hold an unbounded content cache while idle?

Answer format: cite the exact source file/line or changelog/doc passage from the fff project (GitHub: likely under an org name matching "fff" or "fpcMotif/fff" — check the Package.resolved / Package.swift dependency URL in this repo first) that defines this behavior. If the source is not publicly available or the crate is closed, say so explicitly rather than inferring from the option name. Note: this repo has prior internal notes at `.scratch/fff-search-bench/research/fff-engine-landscape.md` and `.scratch/optimization/findings-index.md` (entries U11, U18) claiming 0 means "engine default/auto-sized" — treat those as a starting hypothesis to confirm or refute against the actual source, not as ground truth.
```

## Research: does NSPasteboard synthesize TIFF lazily or does screencapture always publish both types? (sharpens F162)

```
Context: Floodlight is a macOS 14-26 app (Swift 6.4, AppKit + SwiftUI) with a clipboard-history feature that reads `NSPasteboard.general.data(forType: .png)` and `.data(forType: .tiff)` on every pasteboard change (polling `changeCount` at 2 Hz). When a user copies a screenshot (via Cmd+Shift+4/Control+Cmd+Shift+4, or Preview/Safari "Copy Image"), the app observes both a `public.png` and a `public.tiff` representation and stores both to disk, capped at 15 MB each independently.

Question: For macOS 14 through 26, when an application (e.g., the macOS screenshot tool, Preview, Safari, Photos) copies an image to the general pasteboard declaring `public.tiff` as one of its `types`, does calling `NSPasteboard.data(forType: .tiff)` trigger AppKit to synthesize a fresh TIFF representation on demand from the underlying image (a real-time re-encode cost paid at read time), or is the TIFF representation already fully materialized on the pasteboard by the source app at copy time (so reading it is just an IPC fetch with no synthesis cost)? Does this differ between a promised/lazy pasteboard item (`NSPasteboardItemDataProvider`) and an eagerly-written one?

Answer format: cite Apple documentation (NSPasteboard, NSPasteboardWriting, NSPasteboardItemDataProvider) or WWDC session material. State clearly whether reading `.tiff` data from a pasteboard that also offers `.png` is ever a compute-cost event versus a pure IPC/memory-copy cost, since this affects whether Floodlight should read `.tiff` at all when `.png` is already available.
```


# Upstream FFF

## Upstream: how Floodlight drives the FFF C API

```
Title: Confirm neo_frizbee 0.11 threading model for U6
Context: macOS 14+, Swift 6.4, fff-core 0.10.5 (vendored in Floodlight) / 0.10.6 (upstream main).
fff-core's fuzzy_search / fuzzy_search_mixed pass `max_threads` straight into
`neo_frizbee::match_list_parallel_resolved` (score.rs:341,457,660). neo_frizbee
0.11.0 is a crates.io dependency, not vendored — its source is not in either
checkout available to static analysis.
Question: Does match_list_parallel_resolved partition work into static equal-sized
chunks per thread (so E-core stragglers slow the whole call down — fewer threads
would help) or use dynamic/work-stealing scheduling (so extra threads add pure
throughput with no straggler penalty — more threads would help)? Also: does it
spawn new OS threads per call, or reuse an existing (rayon-global or self-managed)
pool?
Desired answer form: cite the neo_frizbee source (crates.io or its repo) directly —
function/module name and a short quote — plus a one-line verdict on which direction
(fewer vs more threads) the U6 thread-count question should resolve to before any
Mac benchmarking is run.
```

```
Title: Verify cbindgen/XCFramework ABI story for a versioned FffMixedItem
Context: fff-swift 0.2.1 ships CFFF.xcframework as a checksummed binaryTarget built
by scripts/build-xcframework.sh from Vendor/fff/crates/fff-c. FffMixedItem's items
array is stride-indexed via `result.items.add(index)` (fff-c/src/lib.rs), with no
version field (unlike FffCreateOptions, which has FFF_CREATE_OPTIONS_VERSION).
Question: What is the minimal, genuinely ABI-safe way to add relative_path_len /
display_name_offset fields to FffMixedItem — a trailing "extension" struct pointer,
a separate parallel array, or a full struct-version bump requiring a coordinated
fff-swift release + Package.swift checksum update in Floodlight? Confirm whether
cbindgen 0.29.x has any built-in support for versioned/extensible repr(C) structs
that would avoid a hard break for existing consumers.
Desired answer form: a short decision doc (under 300 words) naming the safest
mechanism, with a code sketch of the chosen struct layout.
```

None of the other 13 items in this section need external research beyond the Mac experiments already listed in the TODO — all remaining open questions are answerable by reading the vendored code (already done) or by running the benchmarks/Instruments captures on the maintainer's own Mac.

## Upstream: fff-core query path (make it blazing fast)

```research-prompt title="neo_frizbee 0.11 max_typos and prefix-monotonicity semantics" ids="U21,U32"
Context: macOS 14+, Rust (stable toolchain per fff-swift/Vendor/fff), fff-search 0.10.5 vendored fork of dmtrKovalenko/fff, dependency `neo_frizbee = "0.11"` declared in Vendor/fff/Cargo.toml but not vendored into the checkout (external crates.io crate).

Question 1 (blocks U21): Is `neo_frizbee::Config.max_typos` strictly "count of needle characters allowed to go unmatched against the haystack" (i.e. a file matches iff at least `needle_len - max_typos` needle characters appear in order in the haystack), or does it additionally apply a Smith-Waterman score floor / minimum contiguous-match requirement that would change the "needle_len <= max_typos ⇒ universal match" reasoning? Read `~/.cargo/registry/src/*/neo_frizbee-0.11.0/src/` (the prefilter and match_list_parallel_resolved implementation) directly, not just fff's own comments about it.

Question 2 (blocks U32): Is the match predicate monotone under needle prefixes at a fixed typo budget — does `matches(haystack, q, t)` imply `matches(haystack, q[..k], t)` for all `k <= |q|`? This is the precondition for any prefix-based incremental narrowing cache. If not exactly monotone, characterize the failure mode (e.g. does a fixed *alignment* stay valid under prefix truncation, or can typo credits be "spent" ahead of the truncation point in a way that breaks it?).

Desired answer form: (a) a yes/no per question with the specific source lines/functions cited from the actual neo_frizbee 0.11.0 source tree, (b) if question 1's answer differs from the needle-length model, a corrected typo_budget table for fff-core/src/file_picker.rs, (c) if question 2 is false in general, either a narrower sufficient condition under which it does hold (e.g. "true when max_typos is non-decreasing AND ≤ 1", if that's the actual boundary) or a recommendation to drop U32 entirely.
```

```research-prompt title="fff-c mimalloc feasibility inside a static XCFramework" ids="U22,U24,U31,U37"
Context: macOS 14+, Swift 6.4 app (Floodlight) linking a static XCFramework built from `fff-swift/Vendor/fff/crates/fff-c` (a Rust staticlib, no existing `#[global_allocator]`). `fff-nvim` and `fff-mcp` both set `#[global_allocator] static ALLOC: mimalloc::MiMalloc = mimalloc::MiMalloc;`, but that replaces the allocator for the whole binary — unacceptable for a staticlib linked into someone else's Swift process, since it would silently replace `malloc` for the entire host app.

Question: Can `libmimalloc-sys` be used in override-free mode — i.e. call `mi_malloc`/`mi_free` explicitly only for the specific hot Vec allocations identified in this report (the match-result Vec in `score.rs`, the frecency-path Vec, the overflow-extend Vec), via a custom `std::alloc::Allocator` implementation scoped to just those types, without touching `#[global_allocator]` — while still linking cleanly into a static XCFramework consumed by a Swift 6.4 app? Are there known linker/symbol-collision issues when a staticlib embeds mimalloc's C sources alongside a host app that also uses system malloc?

Desired answer form: a yes/no on feasibility, a minimal Cargo.toml/build.rs sketch if yes, and any known caveats specific to static (not dylib) linking into an Xcode-built macOS app target.
```

## Upstream: index scan, cold start, and persistence

None needed for this section.

## Upstream: XCFramework build flags and toolchain

## Research prompts — Upstream: XCFramework build flags and toolchain

```
TITLE: Does ignore::DirEntry::metadata() perform a stat syscall on macOS beyond readdir's d_type? [U57]

CONTEXT: fff (dmtrKovalenko/fff, vendored at 0.10.5 inside vmg-dev/fff-swift 0.2.1) has two
file-walker backends selected by a Cargo feature: `ripgrep` (default, wraps the `ignore` crate)
and `zlob` (a Zig-backed walker, upstream's release default). The ripgrep backend calls
`entry.metadata().ok()` once per walked file (crates/fff-core/src/walk/ripgrep.rs:60), while the
zlob backend bulk-fetches SIZE|MTIME during traversal itself. The claim under test: on macOS,
ignore::DirEntry::metadata() issues a lstat(2) syscall per entry, because walkdir (which `ignore`
wraps) does not cache size/mtime from the readdir(3) call that already produced d_type.

QUESTION: On macOS (APFS), does calling .metadata() on an ignore::DirEntry / walkdir::DirEntry
actually invoke lstat per call, or does walkdir/ignore cache metadata from an earlier readdir-family
syscall (e.g. getdirentriesattr, or readdir_r with DT_* fields) such that .metadata() is free or
near-free?

DESIRED ANSWER FORM: A yes/no on whether a syscall is incurred, with either (a) a citation to
walkdir/ignore source showing whether DirEntry stores a pre-fetched libc::stat/dirent struct, or
(b) a measured syscall count via `sudo fs_usage -w -f filesys <pid>` filtered to stat64/lstat64
during a walk of a ~100k-file directory tree with the ripgrep backend, compared to a walk with
metadata() calls stripped out. State the walkdir/ignore crate versions checked (fff pins them via
Cargo.lock in Vendor/fff).
```

```
TITLE: Does the `mimalloc` crate (0.1.47, local_dynamic_tls) interpose process-wide malloc/free? [U63]

CONTEXT: fff-swift's vendored fff-c crate (crates/fff-c/src/lib.rs) is compiled as a static
library (`crate-type = ["cdylib", "staticlib"]`) and linked into a Swift/AppKit macOS app
(Floodlight). Two other consumers in the same Cargo workspace (fff-nvim, fff-mcp) already set
`#[global_allocator] static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;` using
`mimalloc = "0.1.47"` with the `local_dynamic_tls` feature and no other features enabled. The
proposal is to do the same in fff-c, on the premise that the `mimalloc` crate's default Cargo
feature set does NOT enable libmimalloc-sys's `override` feature — i.e. it only supplies Rust's
internal `__rust_alloc`/`__rust_dealloc` allocator-shim symbols, and never defines or interposes
the process's `malloc`/`free`/`calloc`/`realloc` C symbols. If that premise is wrong, linking this
into a static archive consumed by a host Swift/Foundation/AppKit process would silently override
process-wide malloc, causing allocator-mismatch corruption (Rust-side mimalloc, Swift-side
Foundation calling libmalloc's free, or vice versa) via any pointer that crosses without going
through fff.h's documented fff_free_* functions.

QUESTION: For `mimalloc = "0.1.47"` compiled with only the `local_dynamic_tls` feature (default
features otherwise, no `override`/`secure`/`no_thread_id` etc.), does the resulting static
library define global symbols named `malloc`, `free`, `calloc`, `realloc`, or `posix_memalign`
that would collide with / override libSystem's implementations when statically linked into a
host executable?

DESIRED ANSWER FORM: Yes/no, with either (a) a citation to the mimalloc/libmimalloc-sys crate's
build.rs or Cargo.toml default-features definition showing `override` is off by default, or
(b) an empirical check: build a minimal cdylib/staticlib crate with just
`#[global_allocator] static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;` and run
`nm -gU libtest.a | grep -E '^[0-9a-f]* T _(malloc|free|realloc|calloc)$'` — report whether that
grep is empty.
```

```
TITLE: What is rustc's default -C target-cpu for aarch64-apple-darwin, and does it imply +dotprod/+neon? [U68]

CONTEXT: fff-swift builds its XCFramework's static library (libfff_c.a) for the
aarch64-apple-darwin target with no explicit `-C target-cpu` flag set anywhere in the build
(fff-swift/scripts/build-xcframework.sh, and Vendor/fff/.cargo/config.toml carries only link-arg
flags, no target-cpu). Two SIMD code paths in the vendored fff-core crate branch on CPU features:
crates/fff-core/src/simd_string_utils/case.rs:126-130 does a RUNTIME check via
`std::arch::is_aarch64_feature_detected!("dotprod")`, and
crates/fff-core/src/index/bigram_filter.rs:604-607 gates `normalize_bytes_neon` on the
COMPILE-TIME `target_feature = "neon"` cfg (falling back to a scalar path if absent at compile
time). The open question is whether rustc's baseline target-cpu for aarch64-apple-darwin (as
resolved by the toolchain pinned in fff-swift/Vendor/fff/rust-toolchain.toml, channel "stable")
already implies these features by default, making an explicit `-C target-cpu=apple-m1` a no-op
guard rather than a functional change.

QUESTION: As of Rust stable in 2025/2026 (rustc 1.8x), what is the default target-cpu baseline
used for the aarch64-apple-darwin target triple when no `-C target-cpu` is passed, and does that
default set imply the `neon` and `dotprod` target features? (Believed, per Rust compiler team
discussions since ~1.71, to default to something equivalent to `apple-m1` for this triple —
confirm or refute with a primary source.)

DESIRED ANSWER FORM: State the exact default target-cpu string rustc resolves to for
aarch64-apple-darwin absent any flag, and list which of {neon, dotprod, fp16, aes} it implies.
Cite either rustc's target-spec source (compiler/rustc_target/src/spec/targets/aarch64_apple_darwin.rs
or similar) or the direct empirical command `rustc --print cfg --target aarch64-apple-darwin | grep target_feature`
output, noting the rustc version the output came from.
```

```
TITLE: Does -Cprofile-generate/-Cprofile-use compose with lto="fat" + crate-type=staticlib on aarch64-apple-darwin? [U72]

CONTEXT: fff-swift's vendored Rust workspace (Vendor/fff/Cargo.toml) builds fff-c with
`[profile.release] opt-level = 3, lto = "fat", codegen-units = 1` and
`crates/fff-c/Cargo.toml` sets `crate-type = ["cdylib", "staticlib"]`. A proposed two-stage PGO
build would add `RUSTFLAGS="-Cprofile-generate=<dir>"` for an instrumented build, run a workload
through a C driver (crates/fff-c/tests/smoke.c) linked against the instrumented static library,
merge the resulting raw profile data with `llvm-profdata merge`, then rebuild with
`-Cprofile-use=<merged.profdata>`. Two known risk points: (1) LLVM's profile instrumentation
counters are normally initialized/flushed by a runtime (compiler-rt's profile runtime,
`__llvm_profile_write_file` etc.) that Rust's std normally registers an atexit hook for in a
binary/cdylib, but a `staticlib` consumed by an external C `main` may need that hook invoked
explicitly or the runtime symbols linked manually (e.g. via `-lclang_rt.profile_osx` from the
active Xcode toolchain's clang resource directory); (2) fat LTO combined with PGO instrumentation
is a documented but less-common combination that can hit crashes or miscompilations in some LLVM
versions when codegen-units=1.

QUESTION: On the toolchain pinned by fff-swift/Vendor/fff/rust-toolchain.toml (stable channel),
targeting aarch64-apple-darwin: does `cargo build -p fff-c --release --target aarch64-apple-darwin`
with `RUSTFLAGS="-Cprofile-generate=/tmp/pgo"` produce a `libfff_c.a` whose profile counters are
correctly written to disk when driven by an external C program (not a Rust `fn main`) via
`crates/fff-c/tests/smoke.c`, and does `llvm-profdata merge` succeed on the resulting `.profraw`
files without additional linker flags? If it fails, what exact link flag (e.g.
`-lclang_rt.profile_osx`, `-L <xcode>/usr/lib/clang/<ver>/lib/darwin`) resolves it?

DESIRED ANSWER FORM: A step-by-step confirmation (commands + observed output) of the
instrument-run-merge-rebuild cycle succeeding for this exact crate-type/profile combination on
macOS/aarch64, including the exact linker invocation used for the C smoke driver and any
additional flags needed beyond what's in the finding's proposal. If any step fails, give the
error text and the fix.
```

## Upstream: version drift, re-vendoring, and backports

### Research prompt: `next_file_offset` cursor stability across concurrent index mutations (U85)

```
Context: macOS 14+, Swift 6.4, fff-c ABI as shipped in fff-swift 0.2.1 (vendored fff 0.10.5,
commit 459ebcdbdba094843fe5339a1a7f7dae4ced2d82). File: fff-swift/Vendor/fff/crates/fff-c/include/fff.h,
`fff_grep_result_get_next_file_offset`. Engine: fff-swift/Vendor/fff/crates/fff-core (fff_live_grep /
fff_multi_grep implementation, likely in crates/fff-core/src/grep.rs or similar — locate via
`rg -n next_file_offset crates/fff-core`).

Question: is the `file_offset` returned by `fff_grep_result_get_next_file_offset` a stable index into
a fixed underlying file list, or does it reference a position that can shift when the watcher adds new
files or tombstones existing ones between two paginated `fff_live_grep` calls for the same query? If a
file is inserted before the current offset between call N and call N+1, does resuming from the returned
offset skip a file, repeat one, or is it defined against a stable base index unaffected by watcher
overflow additions?

Desired answer form: cite the exact function/struct that produces and consumes the offset (file:line),
state whether the offset is an index into `sync_data.files` (base + overflow) or something else, and
give a one-paragraph verdict: "stable under concurrent mutation" / "not stable — here's the specific
scenario that breaks it" / "undefined, needs upstream clarification (open an issue at
dmtrKovalenko/fff with this question)". This gates whether Floodlight can safely implement grep
pagination (finding U85) without needing to re-run full queries from offset 0 whenever the watcher fires
between keystrokes.
```

