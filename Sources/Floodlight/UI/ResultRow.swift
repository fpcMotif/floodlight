import AppKit
import SwiftUI

struct ResultRow: View, Equatable {
    let item: SearchItem
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    static func == (lhs: ResultRow, rhs: ResultRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
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
        .frame(height: FloodlightMetrics.resultRowHeight)
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

private struct ResultIcon: View {
    let item: SearchItem
    @State private var fileIcon: NSImage?

    var body: some View {
        Group {
            if let fileIcon {
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
        case .calculator: .orange
        case .systemSetting: .gray
        case .web: .blue
        case .application, .file, .folder: .accentColor
        }
    }
}
