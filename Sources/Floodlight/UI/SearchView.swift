import AppKit
import FloodlightEngine
import SwiftUI

struct SearchView: View {
    let model: SearchCoordinator
    let usesGlassSlab: Bool
    let boardContext: ClipboardBoardContext
    @Environment(\.colorScheme) private var colorScheme

    init(
        model: SearchCoordinator,
        usesGlassSlab: Bool = false,
        boardContext: ClipboardBoardContext = ClipboardBoardContext()
    ) {
        self.model = model
        self.usesGlassSlab = usesGlassSlab
        self.boardContext = boardContext
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
            SearchResultsSection(model: model, boardContext: boardContext)
        }
        .frame(
            width: FloodlightMetrics.resolvedPanelWidth(isClipboardMode: model.isClipboardMode),
            alignment: .top
        )
        .modifier(FloodlightSurface())
        .clipShape(
            RoundedRectangle(
                cornerRadius: FloodlightMetrics.cornerRadius,
                style: .continuous
            )
        )
        .overlay {
            if !usesGlassSlab {
                RoundedRectangle(
                    cornerRadius: FloodlightMetrics.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [
                                .white.opacity(0.35),
                                .white.opacity(0.12),
                                .white.opacity(0.06),
                            ]
                            : [
                                .white.opacity(0.8),
                                .black.opacity(0.12),
                                .black.opacity(0.06),
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
            }
        }
    }
}

private struct SearchBar: View {
    @Bindable var model: SearchCoordinator
    @State private var isClearButtonHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FloodlightMetrics.searchIconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(
                    width: FloodlightMetrics.searchIconSize,
                    height: FloodlightMetrics.searchIconSize
                )
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }

            if let engine = model.activeWebEngine {
                WebModeToken(engine: engine)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            } else if model.isClipboardMode {
                ClipboardModeToken()
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }

            FloodlightTextField(
                text: $model.query,
                placeholder: model.isClipboardMode ? "Filter clipboard" : "Floodlight",
                focusGeneration: model.focusGeneration,
                onSubmit: model.openSelection,
                onCommandSubmit: model.revealSelection,
                onOptionSubmit: model.copySelection,
                // Esc is layered by the coordinator: exit web mode first,
                // dismiss the panel second.
                onCancel: model.handleEscape,
                onTab: model.handleTab,
                onShiftTab: model.handleShiftTab,
                onBackspaceOnEmpty: model.handleBackspaceOnEmptyQuery
            )

            trailingAccessory
                .transaction { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
        }
        .padding(.horizontal, 20)
        .frame(height: FloodlightMetrics.searchHeight, alignment: .center)
        // No background in any mode (#94): the row's surface is the shared
        // glass slab, so the bar is the same capsule whichever mode the
        // panel is in. A legibility treatment here would have to apply to
        // every mode, not one.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    /// A clear button once there's a query to clear, or — while idle, if
    /// the registered shortcut is known — a trailing hint chip naming it.
    /// The two are mutually exclusive by construction (the chip only shows
    /// when the field is empty), so this is one slot, not an overlay.
    @ViewBuilder
    private var trailingAccessory: some View {
        if !model.query.isEmpty {
            Button {
                model.query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: FloodlightMetrics.clearButtonSize))
                    .foregroundStyle(isClearButtonHovered ? .primary : .secondary)
                    .frame(
                        width: FloodlightMetrics.clearButtonSize,
                        height: FloodlightMetrics.clearButtonSize
                    )
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isClearButtonHovered = $0 }
            .accessibilityLabel("Clear search")
        } else if model.isClipboardMode {
            if let shortcut = model.activeClipboardShortcutDisplayName {
                KeyChip(label: shortcut)
                    .accessibilityLabel("Clipboard shortcut \(shortcut)")
            }
        } else if let shortcut = model.activeShortcutDisplayName {
            KeyChip(label: shortcut)
                .accessibilityLabel("Summon shortcut \(shortcut)")
        }
    }
}

/// The web-mode token on the field's leading edge: the active engine's
/// title beside the web kind's globe, in the same chip language as the
/// filter bar. Purely indicative — exiting the mode is Esc/Shift-Tab/
/// backspace-on-empty, so the token needs no interaction of its own.
private struct WebModeToken: View {
    let engine: KeywordEngine

    var body: some View {
        Image(systemName: engine.symbolName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(engine.tint.color)
            .frame(width: 26, height: 26)
            .modifier(FloodlightChipSurface(isSelected: true))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(engine.name)
    }
}

private struct ClipboardModeToken: View {
    var body: some View {
        Image(systemName: "doc.on.clipboard")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 26, height: 26)
            .modifier(FloodlightChipSurface(isSelected: true))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Clipboard")
    }
}

/// Branches on Clipboard mode exactly once: the board is a different body
/// with a different owner of its facts (Clipboard Search, ADR 0008), so the
/// local and web paths below never ask which mode they are in.
private struct SearchResultsSection: View {
    let model: SearchCoordinator
    let boardContext: ClipboardBoardContext

    var body: some View {
        if model.isClipboardMode {
            // No divider here: the well's own top edge — where its opaque
            // fill starts — is the separation from the glass search row
            // above it (#57 "glass field, solid well").
            ClipboardWell(
                model: model,
                clipboardSearch: model.clipboardSearch,
                boardContext: boardContext
            )
        } else if !model.query.isEmpty {
            Divider().opacity(0.45)
            // Web mode publishes no filter options — rendering the bar
            // anyway leaves an empty strip between the field and the
            // rows. Its height goes to the results, so the panel never
            // resizes.
            if showsFilterBar {
                SearchFilterBar(model: model)
            }
            resultsContent
                .frame(height: resultsHeight)
        }
    }

    private var showsFilterBar: Bool {
        !model.filterOptions.isEmpty
    }

    private var resultsHeight: CGFloat {
        FloodlightMetrics.panelHeight(hasQuery: true, isClipboardMode: false)
            - FloodlightMetrics.searchHeight
            - 1
            - (showsFilterBar ? FloodlightMetrics.filterBarHeight : 0)
    }

    @ViewBuilder
    private var resultsContent: some View {
        if model.results.isEmpty {
            EmptyResultsView(filter: model.selectedFilter, query: model.query)
        } else {
            ResultList(model: model)
        }
    }
}

/// The board body (#57 review): filter bar, list/inspector, footer
/// divider, and footer sit on one opaque "well" — a solid fill with a
/// hairline inside stroke, inset from the panel's glass on its leading,
/// trailing, and bottom edges only, so its top edge reads as the seam
/// between the glass field above and the solid board below.
///
/// The list and the filter bar are the session's rows and intents, so they
/// keep the coordinator; the inspector and the footer's affordances read
/// what Clipboard Search publishes about the selection.
private struct ClipboardWell: View {
    let model: SearchCoordinator
    let clipboardSearch: ClipboardSearch
    let boardContext: ClipboardBoardContext

    var body: some View {
        VStack(spacing: 0) {
            if showsFilterBar {
                SearchFilterBar(model: model)
            }
            content
                .frame(height: contentHeight)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(wellShape)
        .overlay(
            wellShape.strokeBorder(
                Color.primary.opacity(FloodlightMetrics.clipboardWellStrokeOpacity),
                lineWidth: 1
            )
        )
        .padding(.leading, FloodlightMetrics.clipboardWellInset)
        .padding(.trailing, FloodlightMetrics.clipboardWellInset)
        .padding(.bottom, FloodlightMetrics.clipboardWellInset)
    }

    private var showsFilterBar: Bool {
        !model.filterOptions.isEmpty
    }

    /// The board has no divider under the search row to subtract — it
    /// subtracts the well's own bottom inset instead, since that space also
    /// sits outside the content this height is sized for.
    private var contentHeight: CGFloat {
        FloodlightMetrics.panelHeight(hasQuery: true, isClipboardMode: true)
            - FloodlightMetrics.searchHeight
            - FloodlightMetrics.clipboardWellInset
            - (showsFilterBar ? FloodlightMetrics.filterBarHeight : 0)
    }

    private var wellShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: FloodlightMetrics.clipboardWellCornerRadius,
            style: .continuous
        )
    }

    @ViewBuilder
    private var content: some View {
        if model.results.isEmpty {
            EmptyResultsView(
                filter: model.selectedFilter,
                query: model.query,
                isClipboardMode: true
            )
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ResultList(model: model)
                        .frame(width: FloodlightMetrics.clipboardListWidth)
                    Divider().opacity(0.45)
                    ClipboardInspectorPane(
                        snapshot: clipboardSearch.inspector,
                        imagePayloadProvider: { [clipboardSearch] entryID in
                            clipboardSearch.fullImageData(for: entryID)
                        }
                    )
                    .frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.03))
                }
                Divider().opacity(0.45)
                ClipboardFooterBar(
                    entryCount: model.results.count,
                    commands: ClipboardBoardCommands(session: model),
                    clipboardSearch: clipboardSearch,
                    boardContext: boardContext
                )
            }
        }
    }
}

/// Shown only when the active filter yields zero rows — the unfiltered
/// list is never empty, since the web fallback always fills the last slot.
/// Selection and key handling need no special-casing: an empty `results`
/// array already behaves as an ordinary zero-row list everywhere else.
private struct EmptyResultsView: View {
    let filter: SearchResultFilter
    let query: String
    let isClipboardMode: Bool

    init(filter: SearchResultFilter, query: String, isClipboardMode: Bool = false) {
        self.filter = filter
        self.query = query
        self.isClipboardMode = isClipboardMode
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(emptyMessage)
                .font(FloodlightMetrics.Typography.emptyState)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        if isClipboardMode {
            if query.isEmpty, filter == .all {
                return "Clipboard history is empty. Copied text, files, and images will appear here."
            }
            if query.isEmpty {
                return "No \(filter.title.lowercased()) clipboard entries"
            }
            return "No matching clipboard \(filter.title.lowercased()) for “\(query)”"
        }
        return ResultShowcase.emptyStateMessage(filter: filter, query: query)
    }
}

private struct SearchFilterBar: View {
    let model: SearchCoordinator

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chips
                .padding(.horizontal, 14)
        }
        .scrollClipDisabled()
        .frame(height: FloodlightMetrics.filterBarHeight)
        .accessibilityLabel("Search filters")
    }

    private var chips: some View {
        chipRow
    }

    private var chipRow: some View {
        HStack(spacing: 7) {
            ForEach(model.filterOptions) { option in
                SearchFilterChip(
                    option: option,
                    isSelected: model.selectedFilter == option.filter
                ) {
                    model.selectFilter(option.filter)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct SearchFilterChip: View {
    let option: SearchFilterOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: option.filter.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text(option.filter.title)
                Group {
                    if option.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .progressViewStyle(.circular)
                    } else {
                        Text(option.count.formatted(.number.notation(.compactName)))
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 27, height: 13)
            }
            .font(FloodlightMetrics.Typography.chip)
            .foregroundStyle(.primary)
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(height: 26)
            .modifier(FloodlightChipSurface(isSelected: isSelected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(option.filter.title)
        .accessibilityValue(
            option.isLoading ? "Loading" : "\(option.count) results"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ResultList: View {
    let model: SearchCoordinator

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                resultStack
                    .padding(FloodlightMetrics.resultPadding)
            }
            .modifier(FloodlightScrollEdge())
            .onChange(of: model.selectedID) {
                guard let selectedID = model.selectedID else { return }
                guard let index = model.results.firstIndex(where: { $0.id == selectedID }) else {
                    return
                }
                guard
                    index == 0
                    || index >= FloodlightMetrics.maximumVisibleResults
                else {
                    return
                }
                proxy.scrollTo(selectedID)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var resultStack: some View {
        // Keep one container identity as progressive snapshots add rows.
        // Swapping VStack for LazyVStack at a count threshold reconstructs
        // every row and briefly replaces loaded icons with placeholders.
        LazyVStack(spacing: 0) {
            resultRows
        }
    }

    /// One flat, ranked list — no grouping. The Top Hit row gets its own
    /// visual treatment from `ResultRow` itself (a taller icon, a heavier
    /// title, a quiet wash), never a section header: #28 explicitly rejects
    /// grouped/sectioned results, so nothing here inserts a divider between
    /// the Top Hit row and the rest.
    @ViewBuilder
    private var resultRows: some View {
        if #available(macOS 26.0, *) {
            ForEach(model.results.enumerated(), id: \.element.id) { index, item in
                row(for: item, index: index)
            }
        } else {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                row(for: item, index: index)
            }
        }
    }

    private func row(for item: SearchItem, index: Int) -> some View {
        Button {
            model.select(item)
        } label: {
            ResultRow(
                item: item,
                isSelected: model.selectedID == item.id,
                isTopHit: !model.isClipboardMode && ResultShowcase.isTopHit(
                    index: index,
                    resultCount: model.results.count,
                    filter: model.selectedFilter
                ),
                assistantState: model.assistantAnswerState(for: item),
                tabCompletionHint: model.tabCompletionHint(for: item),
                isCompact: model.isClipboardMode
            )
            .equatable()
        }
        .buttonStyle(.plain)
        .focusable(false)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    model.activate(item)
                }
        )
        .id(item.id)
        .contextMenu {
            Button("Open") {
                model.activate(item)
            }
            if item.fileURL != nil {
                Button("Show in Finder") {
                    model.revealSelection()
                }
            }
            Divider()
            Button(role: .destructive) {
                model.excludeFromSearch(item)
            } label: {
                Label("Exclude '\(item.title)' from Search", systemImage: "nosign")
            }
        }
        .onDrag {
            guard let url = item.fileURL else {
                return NSItemProvider(object: item.title as NSString)
            }
            return NSItemProvider(contentsOf: url)
                ?? NSItemProvider(object: url.path as NSString)
        }
        .accessibilityLabel(item.title)
        .accessibilityHint("Select \(item.kind.label). Double-click or press Return to open.")
        .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
        .accessibilityAction(.default) {
            model.activate(item)
        }
    }
}

/// The board's footer holds no coordinator: the count and the three
/// Selected-Result commands arrive from the well, and everything that
/// enables a chip is what Clipboard Search publishes.
private struct ClipboardFooterBar: View {
    let entryCount: Int
    let commands: ClipboardBoardCommands
    let clipboardSearch: ClipboardSearch
    let boardContext: ClipboardBoardContext

    /// Names the application that was frontmost when the panel opened (#57),
    /// and says "Copy" once Return cannot paste there (#66).
    private var pasteLabel: String {
        ClipboardBoardContext.pasteLabel(
            targetAppName: boardContext.pasteTargetAppName,
            isDeliveryAvailable: boardContext.isPasteDeliveryAvailable
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(entryCount) \(entryCount == 1 ? "entry" : "entries")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            HStack(spacing: 8) {
                Button(action: commands.paste) {
                    FooterChip(title: pasteLabel, key: "↵")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pasteLabel)

                // Always laid out: arrowing from a previewable entry to a
                // plain one must not slide the other chips sideways.
                Button {
                    boardContext.requestPreview()
                } label: {
                    FooterChip(title: "Preview", key: "␣")
                }
                .buttonStyle(.plain)
                .disabled(!canPreview)
                .opacity(canPreview ? 1 : FloodlightMetrics.footerChipDisabledOpacity)
                .accessibilityLabel("Preview")

                Button {
                    boardContext.requestActions()
                } label: {
                    FooterChip(title: "Actions", key: "⌘K")
                }
                .buttonStyle(.plain)
                .background(
                    ClipboardActionsMenuAnchor(
                        commands: commands,
                        clipboardSearch: clipboardSearch,
                        boardContext: boardContext,
                        pasteLabel: pasteLabel
                    )
                )
                .accessibilityLabel("Actions")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: FloodlightMetrics.clipboardFooterHeight)
        .background(Color.secondary.opacity(0.04))
    }

    /// The published flag, never the preview action — asking that here
    /// stats the disk and writes Quick Look's temporary file on every pass
    /// of the footer's body (#72).
    private var canPreview: Bool {
        clipboardSearch.isSelectionPreviewable
    }
}

/// A footer affordance's label beside its key hint — the one capsule shape
/// `ClipboardFooterBar`'s three buttons share, so their fonts and paddings
/// can never drift apart from each other.
private struct FooterChip: View {
    let title: String
    let key: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}
