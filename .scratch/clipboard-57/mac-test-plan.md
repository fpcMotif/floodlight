# Issue #57 — Mac test plan for branch `feat/clipboard-rich-board-57`

This branch was written on Windows, where nothing Swift compiles. Every step below runs on the
Mac. Work top to bottom: the first section is the compile-and-fix loop, the rest is verification.
Tick boxes as you go and paste any failing output into the PR.

## 0. Build loop (expect a few first-compile fixes)

- [ ] `git checkout feat/clipboard-rich-board-57`
- [ ] `make install-tools` (once)
- [ ] `make format` — formatting is never hand-edited; commit whatever it changes.
- [ ] `swift build` — fix compile errors here first. Likely spots to check if anything fails:
  - `FileThumbnailDecoder.decodeVideoFrame`: `AVAssetImageGenerator.image(at:)` tuple destructuring.
  - ImageIO option keys cast (`[CFString: Any] as CFDictionary`).
  - `ClipboardBoardContext` being `@Observable` with an `@ObservationIgnored` closure property.
  - `ResultRow` memberwise init with the new `isCompact` default after `tabCompletionHint`.
  - `FloodlightPanelController.makeContentController(model:usesGlassSlab:boardContext:)` call site.
- [ ] `swift build -c release` (warnings are errors in `make check-build`; fix warnings too).
- [ ] `make check` — format, lint (strict), ast-grep rules, architecture, build, Periphery dead code.
  - If Periphery flags `FileThumbnailCache.init` or `FileThumbnailDecoder.*` as unused, that is because
    only tests call them: keep the API but add `// periphery:ignore - test seam` with the reason, matching
    the existing convention in the tree.
  - If SwiftLint `file_length` trips on `SearchView.swift`, move `FooterChip` and `ClipboardBoardBacking`
    into a new `Sources/Floodlight/UI/ClipboardFooterBar.swift` together with `ClipboardFooterBar`.

## 1. Unit tests (run the touched suites first, then everything)

- [ ] `swift test --filter FileThumbnailCacheTests`
  - `pngDecodesDirectlyWithoutQuickLook`, `jpegDecodesDirectly`, `svgDecodesThroughNSImage`,
    `missingFileYieldsNil`, `unsupportedExtensionYieldsNil`, `corruptImageFallsThroughToNil`,
    `garbageVideoFallsThroughToNil`, `cacheReturnsTheSameObjectOnSecondLookup`,
    `extensionClassificationIsCaseInsensitive`.
  - If `svgDecodesThroughNSImage` fails on a CI-like machine without an SVG decoder, note it here: `__`
- [ ] `swift test --filter ClipboardInspectorTests`
  - new: `hexColorSnapshotExposesRGBComponents`, `shortAndAlphaHexColorsParse`,
    `codeLinesKeepEmptyLinesStripCarriageReturnsAndCap`.
- [ ] `swift test --filter SearchCoordinatorClipboardModeTests`
  - new: `previewableSelectionURLResolvesForLocalPathTextEntries`.
- [ ] `swift test --filter FloodlightPanelTests`
  - new: `pasteTargetIgnoresFloodlightItselfAndEmptyNames`.
- [ ] `swift test --filter SearchViewRenderingTests`
  - changed: `theClipboardBoardRendersListAndInspector` now renders at 840 pt.
  - new: `compactClipboardRowsRenderLongTitlesAndPathsWithoutGrowing`,
    `theFooterShowsThePasteTargetAndPreviewChip`.
- [ ] `make test` — full suite. Record the total here: `__ tests, __ failures`
- [ ] `make test-performance` — paste the `FLOODLIGHT_BENCH` lines: `__`
- [ ] `make test-sanitizers` (Address + Thread) — the thumbnail decoder runs off-main; TSan must stay quiet.

## 2. Manual verification against #57's user stories

Set-up: `make install`, launch `~/Applications/Floodlight.app`, grant Full Disk Access if prompted.
Put a busy Terminal window and a Finder window behind where the panel appears.

- [ ] **US8 width.** Type `clip`, Tab. The panel widens to 840 pt centred on the same spot; leaving
      clipboard mode (Esc) shrinks it back to 680 pt without drifting sideways.
- [ ] **US9 contrast.** With Terminal text behind the panel, list titles and inspector text stay
      legible (the board has a window-background tint over the glass). Compare with `main` if unsure.
- [ ] **US8 rows.** Copy a file with a 60-character name and a deep path from Finder; copy a
      400-character paragraph from Notes. In the list: one line per title, path truncated in the
      middle, no "CLIPBOARD" badge, no wrapping, the first row is not rendered as a big Top Hit.
- [ ] **US1 image file.** In Finder copy `品牌绿.png` (or any PNG/JPEG/HEIC). Inspector shows the
      picture immediately (direct decode, no QuickLook delay), name below, Information rows: Source
      (Finder icon at 16 px), Type Image, Size, Copied `Today at HH:mm:ss`, Path.
- [ ] **US2 video file.** Copy an `.mp4`/`.mov` in Finder. Inspector shows a frame with the play
      badge. Try a `.webm` too; if it shows nothing, that is the QuickLook → AVFoundation fallback both
      failing for that codec — note the file type here: `__`
- [ ] **US3 path as text.** In Terminal: `echo -n "$HOME/Desktop/shot.png" | pbcopy` (an existing
      screenshot). Row shows the photo glyph; inspector renders the image; Space opens Quick Look.
- [ ] **US4 missing path.** `echo -n "/nowhere/missing.png" | pbcopy`. Row and inspector show the
      path cleanly, no preview, no crash; Space does nothing; Preview chip is absent.
- [ ] **US5 link.** Copy `https://www.example.com/docs?x=1`. Link card shows `example.com` chip and
      the URL in mono; Information shows Domain.
- [ ] **US6 code.** Copy a 12-line Swift snippet and a JSON object. Language chip (`Code` / `JSON`),
      numbered gutter `1…12`, long lines truncate at the right edge instead of wrapping.
- [ ] **US7 colour.** Copy `#3498DB`, then `#fff`, then `#3498DB80`. Swatch renders; the line under
      it reads `#3498DB  rgb(52, 152, 219)`; Information has an `RGB` row; the alpha form shows
      `rgba(…, 0.50)` and a translucent swatch.
- [ ] **US10/11/12 Information table.** For a Notes copy: Source shows the Notes icon + "Notes";
      Copied shows `Today at …`; for something copied yesterday, `Yesterday at …`.
- [ ] **US13 Quick Look.** Space and ⌘Y on an image file entry, a video entry, a captured image
      entry (copy an image from Preview), and a path-as-text entry all open Quick Look.
- [ ] **US14 action bar.** Summon Floodlight from Safari: footer reads `Paste to Safari ↵`. Summon
      from the menu-bar flashlight: it reads `Paste ↵`. With a previewable entry selected a
      `Preview ␣` chip appears; clicking it opens Quick Look; it disappears for plain text entries.
      `Actions ⌘K` still copies (the real action list is issue #58).
- [ ] **US15 filters.** ⌘1–⌘4 switch All/Text/Files/Images with no width flicker.
- [ ] **Regression.** Local mode (no `clip`) is unchanged: 680 pt, Top Hit styling present, badges
      present, Return opens.
- [ ] **Appearance.** Repeat US9 and US7 in Light mode and with Increase Contrast on.
- [ ] **macOS 26 only.** Toggle Reduce Transparency on/off while the board is open; the backing
      tint stays legible on both the glass slab and the fallback material.

## 3. Before the PR

- [ ] `make check && make test && make test-performance`
- [ ] Update docs if you changed behaviour beyond the spec: `docs/src/content/docs/guides/search.mdx`
      (Clipboard mode paragraph: 840 pt board, RGB row, numbered code, Preview chip).
- [ ] `gh pr create --fill --base main` from this branch; reference `Closes #57`.

## 4. Compile-risk checklist (written blind on Windows — confirm each on the Mac)

Each line names the file, the construct, and what "pass" means. Tick when the build accepts it or
when you have fixed it; write the fix next to the box so the PR description can list it.

### Sources
- [ ] `Sources/Floodlight/UI/FloodlightMetrics.swift` — `clipboardPanelWidth` is a `static let`
      computed from two other `static let`s (evaluates to 840). `resolvedPanelWidth(isClipboardMode:)`
      coexists with the `panelWidth` property (different base names now, so no overload clash).
- [ ] `Sources/Floodlight/UI/SearchView.swift` — `import AppKit` added for `Color(nsColor:)`.
      `ClipboardFooterBar.pasteLabel` uses an `if` expression as the property body (Swift 5.9+).
      `FooterChip` and `ClipboardBoardBacking` are file-private structs at the bottom.
- [ ] `Sources/Floodlight/UI/ResultRow.swift` — `var isCompact = false` declared after
      `tabCompletionHint`, so the memberwise init is `ResultRow(item:isSelected:isTopHit:assistantState:tabCompletionHint:isCompact:)`.
      Existing call sites that omit both trailing arguments must still compile.
- [ ] `Sources/Floodlight/UI/ResultRow.swift` — `@ViewBuilder private var subtitleLine` nests
      `if !isCompact { if let … { } if isTopHit { } }`; SwiftLint cyclomatic complexity stays ≤ 13.
- [ ] `Sources/Floodlight/App/FloodlightPanel.swift` — `resize(to size: NSSize)` replaced
      `resize(to height:)`; `observeModelForPanelSize()` replaced `observeQueryForPanelHeight()`;
      no other caller of the old names remains (`rg observeQueryForPanelHeight` should be empty).
- [ ] `Sources/Floodlight/App/FloodlightPanel.swift` — `boardContext.previewHandler = { [weak self] in self?.togglePreview() }`
      type-checks as `@MainActor () -> Void` inside the `@MainActor` controller init.
- [ ] `Sources/Floodlight/App/FloodlightPanel.swift` — `makeContentController(model:usesGlassSlab:boardContext:)`
      is `static`; both the glass and non-glass branches pass `boardContext` through.
- [ ] `Sources/Floodlight/UI/ClipboardBoardContext.swift` — `@MainActor @Observable final class`
      with an `@ObservationIgnored var previewHandler: (@MainActor () -> Void)?`. If the macro
      rejects the attribute order, move `@ObservationIgnored` onto its own line above the `var`.
- [ ] `Sources/Floodlight/UI/FileThumbnailCache.swift` — ImageIO: `[CFString: Any]` dictionary
      cast `as CFDictionary` into `CGImageSourceCreateThumbnailAtIndex`; `import ImageIO` present.
- [ ] `Sources/Floodlight/UI/FileThumbnailCache.swift` — `NSImage(cgImage:size:)` receives
      `NSSize(width: cgImage.width, height: cgImage.height)` (Int arguments; `CGSize` has that init).
- [ ] `Sources/Floodlight/UI/FileThumbnailCache.swift` — `let (cgImage, _) = try await generator.image(at: .zero)`
      resolves to the macOS 13+ async `AVAssetImageGenerator.image(at:)` returning
      `(image: CGImage, actualTime: CMTime)`; `.zero` resolves as `CMTime.zero` via `import AVFoundation`.
- [ ] `Sources/Floodlight/UI/FileThumbnailCache.swift` — `@concurrent private nonisolated static func generate`
      still compiles under the `NonisolatedNonsendingByDefault` feature (same shape as before the
      rewrite); `NSImage` crossing from that context back to `@MainActor` raises no Sendable error.
- [ ] `Sources/Floodlight/UI/FileThumbnailCache.swift` — `init()` is now internal (tests build
      isolated caches). Periphery must not flag it; if it does, the singleton already uses it, so
      the report would be spurious — add `// periphery:ignore` with the reason.
- [ ] `Package.swift` — `.linkedFramework("AVFoundation")` added; `swift build` links.
- [ ] `Sources/Floodlight/UI/ClipboardInspectorPane.swift` — `ForEach(Array(lines.enumerated()), id: \.offset) { index, line in … }`
      (two-parameter closure over a tuple element) type-checks in the `VStack` builder.
- [ ] `Sources/Floodlight/UI/ClipboardInspectorPane.swift` — `.textSelection(.enabled)` applied to
      the numbered `VStack` is accepted (it is a plain `View` modifier).
- [ ] `Sources/Floodlight/UI/ClipboardInspectorPane.swift` — `private extension Color { init(components:) }`
      replaced `init?(hex:)`; no remaining caller of `Color(hex:)` (`rg "Color\(hex" Sources` empty).
- [ ] `Sources/Floodlight/Search/ClipboardInspector.swift` — `ColorComponents` declared before
      `TextClassification` uses it? (Order inside a type does not matter in Swift; listed only so you
      know both live in the same enum.) `String(format: "%.2f", …)` needs Foundation (imported).

### Tests
- [ ] `Tests/FloodlightTests/FileThumbnailCacheTests.swift` — `NSBitmapImageRep(bitmapDataPlanes: nil, …)`
      fixture writes PNG and JPEG that ImageIO decodes; `setColor(_:atX:y:)` uses calibrated colours.
- [ ] `Tests/FloodlightTests/FileThumbnailCacheTests.swift` — `svgDecodesThroughNSImage` depends on
      `NSImage(contentsOf:)` reading SVG on the test host (macOS 11+; should pass on 14+).
- [ ] `Tests/FloodlightTests/FileThumbnailCacheTests.swift` — `garbageVideoFallsThroughToNil` and
      `corruptImageFallsThroughToNil` must finish in seconds; if QuickLook or AVFoundation stalls on
      garbage bytes, wrap the awaited call in a task with a 10 s timeout or drop the `thumbnail(at:)`
      call from those two tests.
- [ ] `Tests/FloodlightTests/FileThumbnailCacheTests.swift` — awaited values are assigned to `let`s
      first and then passed to `try #require(...)`; no `await` inside a macro argument.
- [ ] `Tests/FloodlightTests/SearchViewRenderingTests.swift` — `SearchItem(title:subtitle:kind:action:iconSource:score:)`
      matches the engine initialiser (`id` defaults to nil); `.engine(symbol:tint:)` with `.gray` exists.
- [ ] `Tests/FloodlightTests/SearchViewRenderingTests.swift` — `render(_:width:height:)` accepts a
      `ResultRow` directly (it is generic over `View`).
- [ ] `Tests/FloodlightTests/SearchCoordinatorClipboardModeTests.swift` — the two text entries are
      recorded in order and both appear (different texts, so no dedupe).
- [ ] `Tests/FloodlightTests/FloodlightPanelTests.swift` — `ClipboardBoardContext.pasteTargetName`
      is callable from a non-`@MainActor` test (it is a static pure function on a `@MainActor` class:
      if the compiler insists on isolation, mark the function `nonisolated`).

### Gates
- [ ] `make check-format` — expect churn only where SwiftFormat rewraps the new code; run `make format`.
- [ ] `make check-lint` — `SearchView.swift` is 569 lines (limit 665); `ClipboardInspector.swift` 434.
- [ ] `make check-rules` — passes on Windows with ast-grep 0.39 already; confirm with the pinned 0.45.
- [ ] `make check-dead-code` — new symbols all referenced from production code except test-only
      `FileThumbnailDecoder.decodeImage/decodeVideoFrame/quickLookThumbnail` (each is called by
      `thumbnail(at:)`, so they are live). Report anything Periphery still names.
