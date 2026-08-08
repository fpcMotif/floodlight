import AppKit
import FloodlightEngine
import SwiftUI

struct ResultRow: View, Equatable {
    let item: SearchItem
    let isSelected: Bool
    /// Non-nil only for the row that triggered an "Ask Codex"/"Ask Claude"
    /// — set by `SearchCoordinator.assistantRun`, cleared as soon as the
    /// query changes. Every other row ignores this entirely.
    let assistantState: AssistantAnswerState?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.assistantState == rhs.assistantState
    }

    var body: some View {
        HStack(spacing: 12) {
            ResultIcon(item: item)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(item.kind.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            .secondary.opacity(0.12),
                            in: Capsule()
                        )
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
                        Text(modifiedAt, style: .relative)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                if let assistantState {
                    AssistantAnswerView(state: assistantState)
                }
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(7)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, assistantState == nil ? 0 : 10)
        .frame(minHeight: FloodlightMetrics.resultRowHeight)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        guard isHovered else { return .clear }
        return colorScheme == .dark
            ? .white.opacity(0.075)
            : .black.opacity(0.055)
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
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        case .answered(let text):
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(.top, 2)
        }
    }
}

private struct ResultIcon: View {
    let item: SearchItem
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
                    .padding(8)
                    .foregroundStyle(iconColor)
                    .background(iconColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(width: 38, height: 38)
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

    private var iconColor: Color {
        switch item.kind {
        case .assistant: .purple
        case .calculator: .orange
        case .systemSetting: .gray
        case .web: .blue
        case .application, .file, .folder: .accentColor
        }
    }
}
