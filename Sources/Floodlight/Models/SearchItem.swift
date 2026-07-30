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
