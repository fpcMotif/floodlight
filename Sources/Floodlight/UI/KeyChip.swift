import SwiftUI

/// A small rounded-rect keyboard-hint chip — today the selected row's
/// Return affordance, and (once #1's idle capsule lands) its summon-shortcut
/// hint too. One shared component, so the two specs converge on a single
/// look instead of each hand-rolling a lookalike.
struct KeyChip: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(symbolName: String) {
        content = .symbol(symbolName)
    }

    init(label: String) {
        content = .text(label)
    }

    var body: some View {
        chipContent
            .foregroundStyle(.primary.opacity(contrast == .increased ? 0.95 : 0.82))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 24)
            .background(
                .secondary.opacity(contrast == .increased ? 0.16 : 0.1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay { contrastBorder }
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

    @ViewBuilder
    private var contrastBorder: some View {
        if contrast == .increased {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.primary.opacity(0.55), lineWidth: 0.75)
        }
    }

    private enum Content {
        case symbol(String)
        case text(String)
    }
}
