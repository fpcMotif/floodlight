import AppKit
import FloodlightEngine
import SwiftUI

struct ResultRow: View, Equatable {
    let item: SearchItem
    let isSelected: Bool
    /// True only for the first result of a non-empty, unfiltered list — see
    /// `ResultShowcase.isTopHit`. Drives a taller icon, a heavier title, no
    /// kind badge, and a quiet background wash instead of the standard row.
    let isTopHit: Bool
    /// Non-nil only for the row that triggered an "Ask Codex"/"Ask Claude"
    /// — set by `SearchCoordinator.assistantRun`, cleared as soon as the
    /// query changes. Every other row ignores this entirely.
    let assistantState: AssistantAnswerState?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.isTopHit == rhs.isTopHit
            && lhs.assistantState == rhs.assistantState
    }

    var body: some View {
        HStack(spacing: 12) {
            ResultIcon(item: item, size: isTopHit ? FloodlightMetrics.topHitIconSize : FloodlightMetrics.standardIconSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(isTopHit ? FloodlightMetrics.Typography.topHitTitle : FloodlightMetrics.Typography.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !isTopHit {
                        Text(item.kind.label)
                            .font(FloodlightMetrics.Typography.badge)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                .secondary.opacity(FloodlightMetrics.badgeFillOpacity),
                                in: Capsule()
                            )
                    }
                }

                HStack(spacing: 6) {
                    Text(item.subtitle)
                        .lineLimit(1)

                    if let fileSize = item.fileSize, fileSize > 0 {
                        Text("·")
                        Text(fileSize.formatted(.byteCount(style: .file)))
                    }

                    if let modifiedAt = item.modifiedAt {
                        Text("·")
                        Text(ResultShowcase.formattedModifiedDate(modifiedAt))
                    }

                    if isTopHit {
                        Text("·")
                        Text("Top Hit")
                    }
                }
                .font(FloodlightMetrics.Typography.rowSubtitle)
                .foregroundStyle(.secondary)

                if let assistantState {
                    AssistantAnswerView(state: assistantState)
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                KeyChip(symbolName: "return")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, assistantState == nil ? 0 : 10)
        .frame(minHeight: FloodlightMetrics.resultRowHeight)
        .background {
            RoundedRectangle(cornerRadius: FloodlightMetrics.resultRowCornerRadius, style: .continuous)
                .fill(backgroundColor)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return colorScheme == .dark
                ? .white.opacity(isHovered ? 0.16 : 0.12)
                : .black.opacity(isHovered ? 0.11 : 0.08)
        }
        if isHovered {
            return colorScheme == .dark
                ? .white.opacity(0.075)
                : .black.opacity(0.055)
        }
        if isTopHit {
            return .primary.opacity(FloodlightMetrics.topHitWashOpacity)
        }
        return .clear
    }
}

/// The loading / answer / error content beneath an assistant row's
/// subtitle. Unlike every other row, its height is content-driven — an
/// answer can run longer than one line — so the row it's embedded in uses
/// `minHeight` rather than a fixed height.
private struct AssistantAnswerView: View {
    let state: AssistantAnswerState

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Asking…")
            }
            .font(FloodlightMetrics.Typography.rowSubtitle)
            .foregroundStyle(.secondary)
        case .answered(let text):
            Text(text)
                .font(FloodlightMetrics.Typography.assistantAnswer)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .failed(let message):
            Text(message)
                .font(FloodlightMetrics.Typography.rowSubtitle)
                .foregroundStyle(.red)
                .padding(.top, 2)
        }
    }
}

private struct ResultIcon: View {
    let item: SearchItem
    var size: CGFloat = FloodlightMetrics.standardIconSize
    @State private var fileIcon: NSImage?

    var body: some View {
        Group {
            if item.iconSource == .floodlightApplication {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
            } else if let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: item.kind.symbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.21)
                    .foregroundStyle(FloodlightMetrics.iconTint(for: item.kind))
                    .background(
                        FloodlightMetrics.iconTint(for: item.kind).opacity(FloodlightMetrics.iconTileTintOpacity),
                        in: RoundedRectangle(cornerRadius: FloodlightMetrics.iconTileCornerRadius, style: .continuous)
                    )
            }
        }
        .frame(width: size, height: size)
        .task(id: item.fileURL?.path) {
            guard let url = item.fileURL else {
                fileIcon = nil
                return
            }
            if let cached = FileIconCache.shared.cachedIcon(for: url) {
                fileIcon = cached
            } else {
                fileIcon = await FileIconCache.shared.icon(for: url)
            }
        }
    }
}
