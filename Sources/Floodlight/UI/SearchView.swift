import SwiftUI

struct SearchView: View {
    @ObservedObject var model: SearchCoordinator
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !model.query.isEmpty {
                Divider().opacity(0.45)
                results
            }
        }
        .frame(width: 680, height: model.panelHeight)
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
        }
        .onAppear {
            searchFocused = true
        }
        .onChange(of: model.focusGeneration) {
            searchFocused = true
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(.secondary)

            TextField("Floodlight Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 19)
        .frame(height: 72)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.results) { item in
                        ResultRow(item: item, isSelected: model.selectedID == item.id)
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
                .padding(6)
            }
            .onChange(of: model.selectedID) {
                guard let selectedID = model.selectedID else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }
        }
    }
}
