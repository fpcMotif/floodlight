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

    fileprivate static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp",
    ]

    fileprivate static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "key", "md", "numbers", "pages", "ppt", "pptx", "rtf", "txt", "xls",
        "xlsx",
    ]
}

struct SearchFilterCounts: Equatable, Sendable {
    private var all = 0
    private var applications = 0
    private var files = 0
    private var folders = 0
    private var settings = 0
    private var pdfs = 0
    private var images = 0
    private var documents = 0

    init() {}

    init(items: [SearchItem]) {
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
            case .calculator, .web:
                break
            }
        }
    }

    subscript(filter: SearchResultFilter) -> Int {
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
    case showFloodlightSettings
}

enum SearchItemIconSource: Hashable, Sendable {
    case inferred
    case floodlightApplication
}

struct SearchItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: SearchItemKind
    let action: SearchItemAction
    let iconSource: SearchItemIconSource
    let score: Int
    let fileURL: URL?
    let modifiedAt: Date?
    let fileSize: UInt64?
    private let normalizedFileExtension: String

    init(
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

    var isPreviewable: Bool {
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

    func makeSearchItem() -> SearchItem {
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
