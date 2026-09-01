import AppKit
import FloodlightEngine
import SwiftUI

struct ClipboardInspectorPane: View {
    let snapshot: ClipboardInspector?

    var body: some View {
        Group {
            if let snapshot {
                switch snapshot {
                case let .text(detail):
                    textPane(detail)
                case let .file(detail):
                    filePane(detail)
                case let .image(detail):
                    imagePane(detail)
                }
            } else {
                Text("Select an entry")
                    .font(FloodlightMetrics.Typography.emptyState)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard inspector")
    }

    private func textPane(_ detail: ClipboardInspector.TextDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metadata(sourceApp: detail.sourceApp, createdAt: detail.createdAt)
            ScrollView {
                Text(detail.body)
                    .font(FloodlightMetrics.Typography.rowTitle)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func filePane(_ detail: ClipboardInspector.FileDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FileMediaPreview(url: detail.fileURL)
            Text(detail.name)
                .font(FloodlightMetrics.Typography.topHitTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
            labeled("Type", detail.type)
            if let byteCount = detail.byteCount {
                labeled("Size", UInt64(byteCount).formatted(.byteCount(style: .file)))
            }
            metadata(sourceApp: detail.sourceApp, createdAt: detail.createdAt)
            labeled("Path", detail.path)
        }
    }

    private func imagePane(_ detail: ClipboardInspector.ImageDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let data = detail.previewPNG, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: FloodlightMetrics.resultRowCornerRadius,
                            style: .continuous
                        )
                    )
            }
            Text(detail.name)
                .font(FloodlightMetrics.Typography.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text("\(detail.width)×\(detail.height) · \(byteCount(detail.byteCount))")
                .font(FloodlightMetrics.Typography.rowSubtitle)
                .foregroundStyle(.secondary)
            metadata(sourceApp: detail.sourceApp, createdAt: detail.createdAt)
        }
    }

    private func metadata(sourceApp: String, createdAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            labeled("Source", sourceApp)
            labeled("Copied", ResultShowcase.formattedModifiedDate(createdAt))
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(FloodlightMetrics.Typography.rowSubtitle)
                .foregroundStyle(.secondary)
            Text(value)
                .font(FloodlightMetrics.Typography.rowTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    private func byteCount(_ count: Int) -> String {
        UInt64(count).formatted(.byteCount(style: .file))
    }
}

private struct FileMediaPreview: View {
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var isVideo = false

    var body: some View {
        Group {
            if let thumbnail {
                ZStack(alignment: .center) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 180)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: FloodlightMetrics.resultRowCornerRadius,
                                style: .continuous
                            )
                        )
                    if isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
            }
        }
        .task(id: url) {
            let ext = url.pathExtension.lowercased()
            let videoExtensions: Set = [
                "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg",
            ]
            isVideo = videoExtensions.contains(ext)
            if let cached = FileThumbnailCache.shared.cachedThumbnail(for: url) {
                thumbnail = cached
            } else {
                thumbnail = await FileThumbnailCache.shared.thumbnail(for: url)
            }
        }
    }
}
