import SwiftUI

/// A small rounded-rect keyboard-hint chip — today the selected row's
/// Return affordance, and (once #1's idle capsule lands) its summon-shortcut
/// hint too. One shared component, so the two specs converge on a single
/// look instead of each hand-rolling a lookalike.
struct KeyChip: View {
    private let content: Content

    init(symbolName: String) {
        content = .symbol(symbolName)
    }

    init(label: String) {
        content = .text(label)
    }

    var body: some View {
        chipContent
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 24)
            .background(
                .secondary.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }

    @ViewBuilder
    private var chipContent: some View {
        switch content {
        case let .symbol(name):
            Image(systemName: name)
                .font(FloodlightMetrics.Typography.keyChip)
        case let .text(label):
            Text(label)
                .font(FloodlightMetrics.Typography.keyChip)
        }
    }

    private enum Content {
        case symbol(String)
        case text(String)
    }
}
