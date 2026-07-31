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
            ResultList(model: model)
                .frame(
                    height: FloodlightMetrics.expandedPanelHeight
                        - FloodlightMetrics.searchHeight
                        - 1
                )
        }
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
            ResultRow(item: item, isSelected: model.selectedID == item.id)
                .equatable()
                .id(item.id)
                .onTapGesture(count: 2) {
                    model.select(item)
                    model.openSelection()
                }
                .onTapGesture {
                    model.select(item)
                }
                .onDrag {
                    guard let url = item.fileURL else {
                        return NSItemProvider(object: item.title as NSString)
                    }
                    return NSItemProvider(contentsOf: url)
                        ?? NSItemProvider(object: url.path as NSString)
                }
        }
    }
}
