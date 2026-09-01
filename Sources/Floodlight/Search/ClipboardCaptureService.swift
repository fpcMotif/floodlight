import AppKit
import FloodlightEngine
import Foundation

@MainActor
protocol PasteboardObserving: AnyObject {
    var changeCount: Int { get }
    var pasteboardTypes: [NSPasteboard.PasteboardType]? { get }
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    func filePaths() -> [String]
    func pngData() -> Data?
    func tiffData() -> Data?
    var frontmostApplicationBundleIdentifier: String? { get }
}

@MainActor
final class AppKitPasteboardObserver: PasteboardObserving {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    var pasteboardTypes: [NSPasteboard.PasteboardType]? {
        pasteboard.types
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        pasteboard.string(forType: type)
    }

    func filePaths() -> [String] {
        ClipboardFileReference.paths(from: pasteboard)
    }

    func pngData() -> Data? {
        pasteboard.data(forType: .png)
    }

    func tiffData() -> Data? {
        pasteboard.data(forType: .tiff)
    }

    var frontmostApplicationBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}

enum ClipboardFileReference {
    static let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func paths(from pasteboard: NSPasteboard) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        if let filenames = pasteboard.propertyList(forType: filenamesType) as? [String] {
            for filename in filenames {
                appendCanonicalPath(filename, into: &paths, seen: &seen)
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] {
            for url in urls where url.isFileURL {
                appendCanonicalPath(url.path, into: &paths, seen: &seen)
            }
        }

        if paths.isEmpty, let string = pasteboard.string(forType: .fileURL) {
            appendCanonicalPath(string, into: &paths, seen: &seen)
        }

        return paths
    }

    static func canonicalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file:") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            let path = url.standardizedFileURL.path
            return path.isEmpty ? nil : path
        }
        let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        return path.isEmpty ? nil : path
    }

    private static func appendCanonicalPath(
        _ raw: String,
        into paths: inout [String],
        seen: inout Set<String>
    ) {
        guard let path = canonicalize(raw), seen.insert(path).inserted else { return }
        paths.append(path)
    }
}

@MainActor
final class ClipboardCaptureService {
    static let enabledDefaultsKey = "clipboard-history-enabled"
    static let retentionDaysDefaultsKey = "clipboard-history-retention-days"

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let sensitiveType = NSPasteboard.PasteboardType("com.apple.is-sensitive")

    private let store: ClipboardHistoryStore
    private let observer: any PasteboardObserving
    let exclusions: ClipboardExclusionStore
    private let defaults: UserDefaults
    private let pollInterval: TimeInterval

    private var lastChangeCount: Int
    private var isPaused = false
    private var timer: Timer?
    private var resignActiveObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?

    init(
        store: ClipboardHistoryStore,
        observer: any PasteboardObserving = AppKitPasteboardObserver(),
        exclusions: ClipboardExclusionStore = ClipboardExclusionStore(),
        defaults: UserDefaults = .standard,
        pollInterval: TimeInterval = 0.5
    ) {
        self.store = store
        self.observer = observer
        self.exclusions = exclusions
        self.defaults = defaults
        self.pollInterval = pollInterval
        lastChangeCount = observer.changeCount
    }

    var isEnabled: Bool {
        get {
            if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.enabledDefaultsKey)
        }
        set {
            defaults.set(newValue, forKey: Self.enabledDefaultsKey)
            if newValue {
                lastChangeCount = observer.changeCount
            }
        }
    }

    var retention: ClipboardRetention {
        get {
            let days = defaults.integer(forKey: Self.retentionDaysDefaultsKey)
            if days > 0 {
                return .days(days)
            }
            return .days(30)
        }
        set {
            switch newValue {
            case let .days(days):
                defaults.set(days, forKey: Self.retentionDaysDefaultsKey)
            case .forever:
                defaults.set(-1, forKey: Self.retentionDaysDefaultsKey)
            }
        }
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = observer.changeCount

        pruneOnSchedule()

        let timer = Timer
            .scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.poll()
                }
            }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        resignActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pause()
            }
        }

        becomeActiveObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resume()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        if let resignActiveObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let becomeActiveObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
        lastChangeCount = observer.changeCount
    }

    func poll() {
        guard isEnabled, !isPaused else { return }

        // Rule 1: changeCount unchanged -> zero work
        let currentChangeCount = observer.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        // Rule 2: Own-write marker -> skip
        guard let types = observer.pasteboardTypes else { return }
        guard !types.contains(.floodlightOwnWrite) else { return }

        // Rule 3: Concealed, transient, or is-sensitive type -> skip
        guard !types.contains(Self.concealedType),
              !types.contains(Self.transientType),
              !types.contains(Self.sensitiveType)
        else {
            return
        }

        // Rule 4: Excluded application bundle ID -> skip
        let bundleID = observer.frontmostApplicationBundleIdentifier
        if let bundleID, exclusions.isExcluded(bundleID: bundleID) {
            return
        }

        let filePaths = observer.filePaths().compactMap(ClipboardFileReference.canonicalize)
        if !filePaths.isEmpty {
            for path in filePaths {
                store.recordFile(path: path, sourceAppBundleID: bundleID)
            }
            return
        }

        if let image = ClipboardImageCapture.payload(from: observer) {
            store.recordImage(
                pngData: image.png,
                tiffData: image.tiff,
                thumbnailPNGData: image.thumbnailPNGData,
                width: image.width,
                height: image.height,
                displayName: image.displayName,
                sourceAppBundleID: bundleID
            )
            return
        }

        // Rule 5: Text exceeds 32,000 UTF-8 bytes -> skip entirely
        guard let text = observer.string(forType: .string), !text.isEmpty else { return }
        guard text.utf8.count <= ClipboardHistoryStore.maxTextByteCount else { return }

        // Rules 6 & 7: Dedup consecutive duplicates and record
        store.record(text: text, sourceAppBundleID: bundleID)
    }

    private func pruneOnSchedule() {
        let retention = retention
        Task.detached(priority: .utility) { [store] in
            store.prune(retention: retention)
        }
    }
}
