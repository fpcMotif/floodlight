import AppKit
import FloodlightEngine
import Foundation

extension NSPasteboard.PasteboardType {
    static let floodlightOwnWrite = NSPasteboard.PasteboardType("com.floodlight.own-write")
}

@MainActor
protocol SelectedResultActionEffects {
    func writeToClipboard(_ value: String) -> Bool
    func writeFilesToClipboard(_ paths: [String]) -> Bool
    func writeImageDataToClipboard(png: Data?, tiff: Data?) -> Bool
    func open(_ url: URL, asApplication: Bool) async throws
    func revealInFinder(_ url: URL)
}

@MainActor
struct AppKitSelectedResultActionEffects: SelectedResultActionEffects {
    private typealias VoidContinuation = CheckedContinuation<Void, any Error>

    private enum OpenError: LocalizedError {
        case missingApplication

        var errorDescription: String? {
            "Launch Services completed without returning an application."
        }
    }

    func writeToClipboard(_ value: String) -> Bool {
        Self.writeString(value, to: .general)
    }

    func writeFilesToClipboard(_ paths: [String]) -> Bool {
        Self.writeFiles(paths, to: .general)
    }

    func writeImageDataToClipboard(png: Data?, tiff: Data?) -> Bool {
        Self.writeImage(png: png, tiff: tiff, to: .general)
    }

    static func writeString(_ value: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: .floodlightOwnWrite)
        return pasteboard.setString(value, forType: .string)
    }

    static func writeFiles(_ paths: [String], to pasteboard: NSPasteboard) -> Bool {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        // writeObjects first so filenames/own-write attach to that item.
        // Setting those types first, then writeObjects, creates a second
        // file-url item and a terminal paste concatenates the path twice.
        guard pasteboard.writeObjects(urls as [NSURL]) else { return false }
        pasteboard.setData(Data(), forType: .floodlightOwnWrite)
        pasteboard.setPropertyList(
            urls.map(\.path),
            forType: ClipboardFileReference.filenamesType
        )
        return true
    }

    static func writeImage(png: Data?, tiff: Data?, to pasteboard: NSPasteboard) -> Bool {
        let pngData = png.flatMap { $0.isEmpty ? nil : $0 }
        let tiffData = tiff.flatMap { $0.isEmpty ? nil : $0 }
        guard pngData != nil || tiffData != nil else { return false }
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: .floodlightOwnWrite)
        var wrote = false
        if let pngData {
            wrote = pasteboard.setData(pngData, forType: .png) || wrote
        }
        if let tiffData {
            wrote = pasteboard.setData(tiffData, forType: .tiff) || wrote
        }
        return wrote
    }

    func open(_ url: URL, asApplication: Bool) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let signpost = FloodlightPerformance.begin("OpenSelection")
        defer { FloodlightPerformance.end("OpenSelection", id: signpost) }

        if asApplication {
            try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: configuration
                ) { application, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if application == nil {
                        continuation.resume(throwing: OpenError.missingApplication)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
                NSWorkspace.shared.open(
                    url,
                    configuration: configuration
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@MainActor
final class SelectedResultActionPerformer {
    typealias TrackSelection = @Sendable (
        SearchItem.ID,
        URL,
        String
    ) async -> Void

    private let effects: any SelectedResultActionEffects
    private let assistantRunSession: AssistantRunSession
    private let runningApplicationActivator: any RunningApplicationActivating
    private let recentStore: RecentStore
    private let clipboardImagePayload: (String) -> ClipboardImagePayload?
    private let trackSelection: TrackSelection
    private let onDismiss: @MainActor () -> Void

    init(
        effects: any SelectedResultActionEffects,
        assistantRunSession: AssistantRunSession,
        runningApplicationActivator: any RunningApplicationActivating,
        recentStore: RecentStore,
        clipboardImagePayload: @escaping (String) -> ClipboardImagePayload? = { _ in nil },
        trackSelection: @escaping TrackSelection,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.effects = effects
        self.assistantRunSession = assistantRunSession
        self.runningApplicationActivator = runningApplicationActivator
        self.recentStore = recentStore
        self.clipboardImagePayload = clipboardImagePayload
        self.trackSelection = trackSelection
        self.onDismiss = onDismiss
    }

    func activate(_ item: SearchItem, query: String) {
        switch item.action {
        case let .copy(value):
            guard effects.writeToClipboard(value) else {
                logClipboardFailure(for: item)
                return
            }
            onDismiss()

        case let .copyFiles(paths):
            guard effects.writeFilesToClipboard(paths) else {
                logClipboardFailure(for: item)
                return
            }
            onDismiss()

        case let .copyImage(id):
            guard let payload = clipboardImagePayload(id),
                  effects.writeImageDataToClipboard(png: payload.png, tiff: payload.tiff)
            else {
                logClipboardFailure(for: item)
                return
            }
            onDismiss()

        case let .open(url):
            open(url, for: item, query: query)

        case let .askAssistant(command, arguments):
            assistantRunSession.start(AssistantRequest(
                itemID: item.id,
                command: command,
                arguments: arguments
            ))
        }
    }

    func copy(_ item: SearchItem) {
        let value = copyValue(for: item)
        if !effects.writeToClipboard(value) {
            logClipboardFailure(for: item)
        }
    }

    func reveal(_ item: SearchItem) {
        guard let url = item.fileURL, url.isFileURL else { return }
        effects.revealInFinder(url)
        onDismiss()
    }

    private func open(_ url: URL, for item: SearchItem, query: String) {
        let isApplication = item.kind == .application
        if isApplication {
            let signpost = FloodlightPerformance.begin("ActivateRunningApplication")
            let activated = runningApplicationActivator.activateIfRunning(bundleURL: url)
            FloodlightPerformance.end("ActivateRunningApplication", id: signpost)
            if activated {
                onDismiss()
                recentStore.record(item.id)
                Task { [trackSelection] in
                    await trackSelection(item.id, url, query)
                }
                return
            }
        }

        onDismiss()
        Task { [effects, recentStore, trackSelection] in
            do {
                try await effects.open(url, asApplication: isApplication)
                if isApplication {
                    recentStore.record(item.id)
                }
                await trackSelection(item.id, url, query)
            } catch {
                NSLog(
                    "Floodlight could not open selected %@ result: %@",
                    item.kind.rawValue,
                    error.localizedDescription
                )
            }
        }
    }

    private func copyValue(for item: SearchItem) -> String {
        switch item.action {
        case let .copy(value):
            value
        case let .copyFiles(paths):
            paths.first ?? item.fileURL?.path ?? item.subtitle
        case .copyImage:
            item.title
        case let .open(url):
            url.isFileURL ? url.path : url.absoluteString
        case .askAssistant:
            assistantRunSession.answeredText(for: item.id) ?? item.title
        }
    }

    private func logClipboardFailure(for item: SearchItem) {
        NSLog("Floodlight could not copy selected %@ result.", item.kind.rawValue)
    }
}
