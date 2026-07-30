import AppKit
import SwiftUI

struct ResultRow: View {
    let item: SearchItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ResultIcon(item: item)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text(item.kind.label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? .white.opacity(0.16) : .secondary.opacity(0.12),
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
                .foregroundStyle(isSelected ? .white.opacity(0.76) : .secondary)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(7)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        }
        .contentShape(Rectangle())
    }
}

private struct ResultIcon: View {
    let item: SearchItem

    var body: some View {
        Group {
            if let url = item.fileURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
