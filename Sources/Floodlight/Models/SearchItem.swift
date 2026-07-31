import Foundation

enum SearchItemKind: String, Hashable, Sendable {
    case application
    case calculator
    case file
    case folder
    case systemSetting
    case web

    var label: String {
        switch self {
        case .application: "Application"
        case .calculator: "Calculator"
        case .file: "File"
        case .folder: "Folder"
        case .systemSetting: "System Setting"
        case .web: "Web Search"
        }
    }

    var symbolName: String {
        switch self {
        case .application: "app.dashed"
        case .calculator: "plus.forwardslash.minus"
        case .file: "doc"
        case .folder: "folder"
        case .systemSetting: "gearshape"
        case .web: "globe"
        }
    }
}

enum SearchResultFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case applications
    case files
    case folders
    case settings
    case pdfs
    case images
    case documents

    static let primary: [SearchResultFilter] = [
        .all,
        .applications,
        .files,
        .folders,
    ]

    static let dynamic: [SearchResultFilter] = [
        .settings,
        .pdfs,
        .images,
        .documents,
    ]

    var id: String { rawValue }

    var title: String {
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

    var isDynamic: Bool {
        Self.dynamic.contains(self)
    }

    func includes(_ item: SearchItem) -> Bool {
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

    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
    ]

    private static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "key", "md", "numbers", "pages", "ppt", "pptx", "rtf", "txt", "xls",
        "xlsx",
    ]
}

struct SearchFilterOption: Identifiable, Equatable, Sendable {
    let filter: SearchResultFilter
    let count: Int
    let isLoading: Bool

    var id: SearchResultFilter { filter }
}

struct SearchItemPage: Sendable {
    let items: [SearchItem]
    let totalMatched: Int
}

enum SearchItemAction: Hashable, Sendable {
    case copy(String)
    case open(URL)
}

struct SearchItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: SearchItemKind
    let action: SearchItemAction
    let score: Int
    let fileURL: URL?
    let modifiedAt: Date?
    let fileSize: UInt64?

    init(
        id: String? = nil,
        title: String,
        subtitle: String,
        kind: SearchItemKind,
        action: SearchItemAction,
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
        self.score = score
        self.fileURL = fileURL
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
    }

    var isRevealable: Bool {
        switch kind {
        case .application, .file, .folder:
            fileURL != nil
        case .calculator, .systemSetting, .web:
            false
        }
    }

    var isPreviewable: Bool {
        kind == .file && fileURL != nil
    }

    fileprivate var fileExtension: String {
        fileURL?.pathExtension.lowercased() ?? ""
    }
}

struct IndexedSearchItem: Sendable {
    let name: String
    let relativePath: String
    let url: URL
    let isDirectory: Bool
    let score: Int
    let modified: UInt64
    let size: UInt64
}

struct IndexedContentItem: Sendable {
    let name: String
    let relativePath: String
    let url: URL
    let line: UInt64
    let snippet: String
}

struct IndexProgress: Equatable, Sendable {
    let scannedFiles: UInt64
    let isScanning: Bool
    let isWatcherReady: Bool
    let isWarmupComplete: Bool
}
