import AppKit
import FloodlightEngine
import SwiftUI

struct ClipboardInspectorPane: View {
    let snapshot: ClipboardInspector?

    var body: some View {
        Group {
            if let snapshot {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        contentPreview(snapshot)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        Divider().opacity(0.4)

                        informationSection(snapshot)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(14)
                }
            } else {
                Text("Select an entry")
                    .font(FloodlightMetrics.Typography.emptyState)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard inspector")
    }

    // MARK: - Content Previews

    @ViewBuilder
    private func contentPreview(_ snapshot: ClipboardInspector) -> some View {
        switch snapshot {
        case let .text(detail):
            textPreview(detail)
        case let .file(detail):
            filePreview(detail)
        case let .image(detail):
            imagePreview(detail)
        }
    }

    @ViewBuilder
    private func textPreview(_ detail: ClipboardInspector.TextDetail) -> some View {
        switch detail.contentType {
        case .link:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                    if let domain = detail.domain {
                        Text(domain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                Text(detail.body)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

        case .color:
            VStack(alignment: .leading, spacing: 8) {
                if let components = detail.colorComponents {
                    RoundedRectangle(
                        cornerRadius: FloodlightMetrics.resultRowCornerRadius,
                        style: .continuous
                    )
                    .fill(Color(components: components))
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: FloodlightMetrics.resultRowCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    )
                    HStack(spacing: 10) {
                        Text(detail.body)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Text(components.rgbDescription)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(detail.body)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

        case .code:
            VStack(alignment: .leading, spacing: 6) {
                if let lang = detail.codeLanguage {
                    Text(lang)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                numberedCodeBlock(detail.body, lineCount: detail.lineCount)
            }

        case .text, .image, .video, .file:
            Text(detail.body)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numberedCodeBlock(_ body: String, lineCount: Int) -> some View {
        let limit = FileTextPreviewDecoder.maxPreviewLines
        return NumberedCodeLines(
            lines: ClipboardInspector.codeLines(body, limit: limit),
            isTruncated: lineCount > limit
        )
    }

    private func filePreview(_ detail: ClipboardInspector.FileDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail.isImage || detail.isVideo {
                FileMediaPreview(url: detail.fileURL)
                    .id(detail.fileURL)
            } else if detail.isText {
                FileTextPreviewContainer(url: detail.fileURL, isCode: detail.isCode)
                    .id(detail.fileURL)
            }
            Text(detail.name)
                .font(FloodlightMetrics.Typography.topHitTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }

    private func imagePreview(_ detail: ClipboardInspector.ImageDetail) -> some View {
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
        }
    }

    // MARK: - Information Section

    private func informationSection(_ snapshot: ClipboardInspector) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Information")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            switch snapshot {
            case let .text(detail):
                infoRow(label: "Source") {
                    sourceAppValue(name: detail.sourceApp, bundleID: detail.sourceAppBundleID)
                }
                infoRow(label: "Type", value: detail.contentType.rawValue)
                if let domain = detail.domain {
                    infoRow(label: "Domain", value: domain)
                }
                if let components = detail.colorComponents {
                    infoRow(label: "RGB", value: components.rgbDescription)
                }
                infoRow(label: "Characters", value: "\(detail.characterCount)")
                infoRow(label: "Words", value: "\(detail.wordCount)")
                if detail.lineCount > 1 {
                    infoRow(label: "Lines", value: "\(detail.lineCount)")
                }
                infoRow(label: "Copied", value: detail.formattedDate)

            case let .file(detail):
                infoRow(label: "Source") {
                    sourceAppValue(name: detail.sourceApp, bundleID: detail.sourceAppBundleID)
                }
                infoRow(label: "Type", value: detail.type)
                if let byteCount = detail.byteCount {
                    infoRow(
                        label: "Size",
                        value: UInt64(byteCount).formatted(.byteCount(style: .file))
                    )
                }
                infoRow(label: "Copied", value: detail.formattedDate)
                infoRow(label: "Path", value: detail.path)

            case let .image(detail):
                infoRow(label: "Source") {
                    sourceAppValue(name: detail.sourceApp, bundleID: detail.sourceAppBundleID)
                }
                infoRow(label: "Type", value: "Image")
                infoRow(label: "Dimensions", value: "\(detail.width) × \(detail.height)")
                infoRow(
                    label: "Size",
                    value: UInt64(detail.byteCount).formatted(.byteCount(style: .file))
                )
                infoRow(label: "Format", value: detail.format)
                infoRow(label: "Copied", value: detail.formattedDate)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func infoRow(label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content()
        }
    }

    private func sourceAppValue(name: String, bundleID: String?) -> some View {
        HStack(spacing: 6) {
            if let icon = AppIconCache.shared.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
    }
}

private struct FileMediaPreview: View {
    let url: URL
    @State private var thumbnail: NSImage?
    @State private var isVideo: Bool

    init(url: URL) {
        self.url = url
        _thumbnail = State(
            initialValue: FileThumbnailCache.shared.immediateImageThumbnail(for: url)
        )
        _isVideo = State(initialValue: FileThumbnailCache.isVideo(url))
    }

    var body: some View {
        ZStack(alignment: .center) {
            RoundedRectangle(
                cornerRadius: FloodlightMetrics.resultRowCornerRadius,
                style: .continuous
            )
            .fill(Color.secondary.opacity(0.06))
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 180)

            if let thumbnail {
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
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: url) {
            guard thumbnail == nil else { return }
            thumbnail = await FileThumbnailCache.shared.thumbnail(for: url)
        }
    }
}

/// Truncation footer shared by the numbered-code and readable-text file
/// previews below.
private struct TruncationFooter: View {
    var body: some View {
        Text("Preview truncated")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
    }
}

/// The gutter-plus-monospace-line layout shared by pasted-code previews and
/// file-backed code previews.
private struct NumberedCodeLines: View {
    let lines: [String]
    let isTruncated: Bool

    var body: some View {
        let gutterWidth = CGFloat(String(lines.count).count) * 7 + 6
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: gutterWidth, alignment: .trailing)
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if isTruncated {
                TruncationFooter()
            }
        }
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isTruncated ? "Code preview, truncated" : "Code preview")
    }
}

private struct FileTextPreviewContainer: View {
    private enum LoadState: Equatable {
        case loading
        case unavailable
        case loaded(FileTextPreview)
    }

    let url: URL
    let isCode: Bool
    @State private var state: LoadState

    init(url: URL, isCode: Bool) {
        self.url = url
        self.isCode = isCode
        if let preview = FileTextPreviewCache.shared.immediatePreview(for: url) {
            _state = State(initialValue: .loaded(preview))
        } else {
            _state = State(initialValue: .loading)
        }
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                // A real placeholder, never `EmptyView`: SwiftUI does not run
                // `.task` on a view with no node, so the earlier `if let` with
                // nothing to show at first appearance never read the file.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel("Loading preview")
            case .unavailable:
                // Only reachable after the task has run, so the missing host
                // view no longer matters.
                EmptyView()
            case let .loaded(preview):
                if preview.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Text("Empty file")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Empty file")
                } else if isCode {
                    NumberedCodeLines(lines: preview.lines, isTruncated: preview.isTruncated)
                } else {
                    readableTextPreview(preview.lines, isTruncated: preview.isTruncated)
                }
            }
        }
        .task(id: url) {
            guard case .loading = state else { return }
            let preview = await FileTextPreviewCache.shared.preview(for: url)
            guard !Task.isCancelled else { return }
            state = preview.map(LoadState.loaded) ?? .unavailable
        }
    }

    private func readableTextPreview(_ lines: [String], isTruncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .lineLimit(FileTextPreviewDecoder.maxPreviewLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isTruncated {
                TruncationFooter()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isTruncated ? "Text preview, truncated" : "Text preview")
    }
}

private extension Color {
    init(components: ClipboardInspector.ColorComponents) {
        self.init(
            red: Double(components.red) / 255,
            green: Double(components.green) / 255,
            blue: Double(components.blue) / 255,
            opacity: components.alpha.map { Double($0) / 255 } ?? 1
        )
    }
}
