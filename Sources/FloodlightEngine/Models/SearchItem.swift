import Foundation

package enum SearchItemKind: String, Hashable, Sendable {
    case application
    case assistant
    case calculator
    case file
    case folder
    case systemSetting
    case web

    package var label: String {
        switch self {
        case .application: "Application"
        case .assistant: "AI Assistant"
        case .calculator: "Calculator"
        case .file: "File"
        case .folder: "Folder"
        case .systemSetting: "System Setting"
        case .web: "Web Search"
        }
    }

    package var symbolName: String {
        switch self {
        case .application: "square.grid.2x2.fill"
        case .assistant: "sparkles"
        case .calculator: "function"
        case .file: "doc.text.fill"
        case .folder: "folder.fill"
        case .systemSetting: "gearshape.fill"
        case .web: "globe.americas.fill"
        }
    }
}

package enum SearchResultFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case applications
    case files
    case folders
    case settings
    case pdfs
    case images
    case documents

    package static let primary: [SearchResultFilter] = [
        .all,
        .applications,
        .files,
        .folders,
    ]

    package static let dynamic: [SearchResultFilter] = [
        .settings,
        .pdfs,
        .images,
        .documents,
    ]

    package var id: String {
        rawValue
    }

    package var title: String {
        switch self {
        case .all: "All"
        case .applications: "Apps"
        case .files: "Files"
        case .folders: "Folders"
        case .settings: "Settings"
        case .pdfs: "PDFs"
        case .images: "Images"
        case .documents: "Documents"
        }
    }

    package var symbolName: String {
        switch self {
        case .all: "sparkle.magnifyingglass"
        case .applications: "square.grid.2x2.fill"
        case .files: "doc.text.fill"
        case .folders: "folder.fill"
        case .settings: "gearshape.fill"
        case .pdfs: "doc.richtext.fill"
        case .images: "photo.fill"
        case .documents: "doc.fill"
        }
    }

    package var isDynamic: Bool {
        Self.dynamic.contains(self)
    }

    package func includes(_ item: SearchItem) -> Bool {
        switch self {
        case .all:
            true
        case .applications:
            item.kind == .application
        case .files:
            item.kind == .file
        case .folders:
            item.kind == .folder
        case .settings:
            item.kind == .systemSetting
        case .pdfs:
            item.kind == .file && item.fileExtension == "pdf"
        case .images:
            item.kind == .file && Self.imageExtensions.contains(item.fileExtension)
        case .documents:
            item.kind == .file && Self.documentExtensions.contains(item.fileExtension)
        }
    }

    fileprivate static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
    ]

    fileprivate static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "key", "md", "numbers", "pages", "ppt", "pptx", "rtf", "txt", "xls",
        "xlsx",
    ]
}

package struct SearchFilterCounts: Equatable, Sendable {
    private var all = 0
    private var applications = 0
    private var files = 0
    private var folders = 0
    private var settings = 0
    private var pdfs = 0
    private var images = 0
    private var documents = 0

    package init() {}

    package init(items: [SearchItem]) {
        for item in items {
            all += 1
            switch item.kind {
            case .application:
                applications += 1
            case .file:
                files += 1
                let fileExtension = item.fileExtension
                if fileExtension == "pdf" {
                    pdfs += 1
                } else if SearchResultFilter.imageExtensions.contains(fileExtension) {
                    images += 1
                } else if SearchResultFilter.documentExtensions.contains(fileExtension) {
                    documents += 1
                }
            case .folder:
                folders += 1
            case .systemSetting:
                settings += 1
            case .assistant, .calculator, .web:
                break
            }
        }
    }

    package subscript(filter: SearchResultFilter) -> Int {
        switch filter {
        case .all: all
        case .applications: applications
        case .files: files
        case .folders: folders
        case .settings: settings
        case .pdfs: pdfs
        case .images: images
        case .documents: documents
        }
    }
}

package struct SearchFilterOption: Identifiable, Equatable, Sendable {
    package let filter: SearchResultFilter
    package let count: Int
    package let isLoading: Bool

    package var id: SearchResultFilter {
        filter
    }

    /// Whether this filter matched nothing — the condition that hides a dynamic
    /// chip, and that sends the selection back to `.all` when the chip the user
    /// is standing on empties out.
    package var isEmpty: Bool {
        count == 0
    }

    package init(filter: SearchResultFilter, count: Int, isLoading: Bool) {
        self.filter = filter
        self.count = count
        self.isLoading = isLoading
    }
}

package struct SearchItemPage: Sendable {
    package let items: [SearchItem]
    package let totalMatched: Int

    package init(items: [SearchItem], totalMatched: Int) {
        self.items = items
        self.totalMatched = totalMatched
    }
}

package enum SearchItemAction: Hashable, Sendable {
    case copy(String)
    case open(URL)
    case showFloodlightSettings
    /// Runs an installed CLI locally and reports its stdout back into the
    /// panel — `command` is a bare executable name and `arguments` are
    /// passed straight to it, never through a shell, so nothing in the
    /// query can be interpreted as shell syntax.
    case askAssistant(command: String, arguments: [String])
}

package enum SearchItemIconSource: Hashable, Sendable {
    case inferred
    case floodlightApplication
}

package struct SearchItem: Identifiable, Hashable, Sendable {
    package let id: String
    package let title: String
    package let subtitle: String
    package let kind: SearchItemKind
    package let action: SearchItemAction
    package let iconSource: SearchItemIconSource
    package let score: Int
    package let fileURL: URL?
    package let modifiedAt: Date?
    package let fileSize: UInt64?
    private let normalizedFileExtension: String

    package init(
        id: String? = nil,
        title: String,
        subtitle: String,
        kind: SearchItemKind,
        action: SearchItemAction,
        iconSource: SearchItemIconSource = .inferred,
        score: Int,
        fileURL: URL? = nil,
        modifiedAt: Date? = nil,
        fileSize: UInt64? = nil
    ) {
        self.id = id ?? "\(kind.rawValue):\(title):\(subtitle)"
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.action = action
        self.iconSource = iconSource
        self.score = score
        self.fileURL = fileURL
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        normalizedFileExtension = kind == .file
            ? fileURL?.pathExtension.lowercased() ?? ""
            : ""
    }

    package var isPreviewable: Bool {
        kind == .file && fileURL != nil
    }

    fileprivate var fileExtension: String {
        normalizedFileExtension
    }
}

extension IndexedSearchItem {
    var isApplicationBundle: Bool {
        isDirectory && url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    }

    package func makeSearchItem() -> SearchItem {
        let kind: SearchItemKind
        let title: String
        if isApplicationBundle {
            kind = .application
            title = url.deletingPathExtension().lastPathComponent
        } else {
            kind = isDirectory ? .folder : .file
            title = name
        }

        return SearchItem(
            id: "\(kind.rawValue):\(url.path)",
            title: title,
            subtitle: relativePath,
            kind: kind,
            action: .open(url),
            score: score,
            fileURL: url,
            modifiedAt: modified > 0
                ? Date(timeIntervalSince1970: TimeInterval(modified))
                : nil,
            fileSize: isDirectory ? nil : size
        )
    }
}
