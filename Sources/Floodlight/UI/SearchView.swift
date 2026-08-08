import FloodlightEngine
import SwiftUI

struct SearchView: View {
    let model: SearchCoordinator

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
            // This crossfade runs unconditionally, Reduce Motion included —
            // it's the substitute for the panel's spatial growth
            // (`FloodlightPanelController.resize` skips its own animation
            // under Reduce Motion), not a faster copy of that motion.
            SearchResultsSection(model: model)
                .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.12), value: model.query.isEmpty)
        .frame(width: FloodlightMetrics.panelWidth)
        .modifier(FloodlightSurface())
        .clipShape(
            RoundedRectangle(
                cornerRadius: FloodlightMetrics.cornerRadius,
                style: .continuous
            )
        )
    }
}

private struct SearchBar: View {
    @Bindable var model: SearchCoordinator
    @State private var isClearButtonHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: FloodlightMetrics.searchIconSize, weight: .regular))
                .foregroundStyle(.secondary)

            if let engine = model.activeWebEngine {
                WebModeToken(title: engine.title)
            }

            FloodlightTextField(
                text: $model.query,
                placeholder: "Floodlight search",
                focusGeneration: model.focusGeneration,
                onSubmit: model.openSelection,
                onCommandSubmit: model.revealSelection,
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
        .frame(height: FloodlightMetrics.searchHeight)
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
            }
            .buttonStyle(.plain)
            .onHover { isClearButtonHovered = $0 }
            .frame(width: FloodlightMetrics.clearButtonSize, height: FloodlightMetrics.clearButtonSize)
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
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: SearchItemKind.web.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
        }
        .font(FloodlightMetrics.Typography.chip)
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .fixedSize()
        .modifier(FloodlightChipSurface(isSelected: true))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Web search mode: \(title)")
    }
}

private struct SearchResultsSection: View {
    @Bindable var model: SearchCoordinator

    var body: some View {
        if !model.query.isEmpty {
            Divider().opacity(0.45)
            SearchFilterBar(model: model)
            resultsContent
                .frame(
                    height: FloodlightMetrics.expandedPanelHeight
                        - FloodlightMetrics.searchHeight
                        - 1
                        - FloodlightMetrics.filterBarHeight
                )
        }
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

/// Shown only when the active filter yields zero rows — the unfiltered
/// list is never empty, since the web fallback always fills the last slot.
/// Selection and key handling need no special-casing: an empty `results`
/// array already behaves as an ordinary zero-row list everywhere else.
private struct EmptyResultsView: View {
    let filter: SearchResultFilter
    let query: String

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text(ResultShowcase.emptyStateMessage(filter: filter, query: query))
                .font(FloodlightMetrics.Typography.emptyState)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SearchFilterBar: View {
    @Bindable var model: SearchCoordinator

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chips
                .padding(.horizontal, 14)
        }
        .scrollClipDisabled()
        .frame(height: FloodlightMetrics.filterBarHeight)
        .accessibilityLabel("Search filters")
    }

    /// Chips share one `GlassEffectContainer` on macOS 26 so adjacent
    /// glass capsules can merge/morph as they scroll — a fallback `HStack`
    /// with no container below 26, where nothing needs to merge.
    @ViewBuilder
    private var chips: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 7) {
                chipRow
            }
        } else {
            chipRow
        }
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
    }
}

private struct SearchFilterChip: View {
    let option: SearchFilterOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
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
    @Bindable var model: SearchCoordinator

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

    @ViewBuilder
    private var resultStack: some View {
        if FloodlightMetrics.shouldVirtualizeResults(count: model.results.count) {
            LazyVStack(spacing: 0) {
                resultRows
            }
        } else {
            VStack(spacing: 0) {
                resultRows
            }
        }
    }

    /// One flat, ranked list — no grouping. The Top Hit row gets its own
    /// visual treatment from `ResultRow` itself (a taller icon, a heavier
    /// title, a quiet wash), never a section header: #28 explicitly rejects
    /// grouped/sectioned results, so nothing here inserts a divider between
    /// the Top Hit row and the rest.
    private var resultRows: some View {
        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
            row(for: item, index: index)
        }
    }

    private func row(for item: SearchItem, index: Int) -> some View {
        Button {
            model.select(item)
        } label: {
            ResultRow(
                item: item,
                isSelected: model.selectedID == item.id,
                isTopHit: ResultShowcase.isTopHit(
                    index: index,
                    resultCount: model.results.count,
                    filter: model.selectedFilter
                ),
                assistantState: model.assistantAnswerState(for: item),
                tabCompletionHint: model.tabCompletionHint(for: item)
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
