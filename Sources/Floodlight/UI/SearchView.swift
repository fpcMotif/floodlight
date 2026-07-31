import SwiftUI

struct SearchView: View {
    let model: SearchCoordinator

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model)
            SearchResultsSection(model: model)
        }
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)

            FloodlightTextField(
                text: $model.query,
                placeholder: "Floodlight search",
                focusGeneration: model.focusGeneration,
                onSubmit: model.openSelection,
                onCommandSubmit: model.revealSelection,
                onCancel: {
                    model.onDismiss?()
                }
            )

            ZStack {
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 20, height: 20)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .padding(.horizontal, 20)
        .frame(height: FloodlightMetrics.searchHeight)
    }
}

private struct SearchResultsSection: View {
    @Bindable var model: SearchCoordinator

    var body: some View {
        if !model.query.isEmpty {
            Divider().opacity(0.45)
            SearchFilterBar(model: model)
            ResultList(model: model)
                .frame(
                    height: FloodlightMetrics.expandedPanelHeight
                        - FloodlightMetrics.searchHeight
                        - 1
                        - FloodlightMetrics.filterBarHeight
                )
        }
    }
}

private struct SearchFilterBar: View {
    @Bindable var model: SearchCoordinator

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
            .padding(.horizontal, 14)
        }
        .scrollClipDisabled()
        .frame(height: FloodlightMetrics.filterBarHeight)
        .accessibilityLabel("Search filters")
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
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.leading, 10)
            .padding(.trailing, 7)
            .frame(height: 26)
            .background(
                isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.055),
                in: Capsule()
            )
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

    private var resultRows: some View {
        ForEach(model.results) { item in
            Button {
                model.activate(item)
            } label: {
                ResultRow(item: item, isSelected: model.selectedID == item.id)
                    .equatable()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .id(item.id)
            .onDrag {
                guard let url = item.fileURL else {
                    return NSItemProvider(object: item.title as NSString)
                }
                return NSItemProvider(contentsOf: url)
                    ?? NSItemProvider(object: url.path as NSString)
            }
            .accessibilityLabel(item.title)
            .accessibilityHint("Open \(item.kind.label)")
        }
    }
}
