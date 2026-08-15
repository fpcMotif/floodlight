import AppKit
import FloodlightEngine
import Foundation

@MainActor
protocol SelectedResultActionEffects {
    func writeToClipboard(_ value: String) -> Bool
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
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
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
    private let trackSelection: TrackSelection
    private let onDismiss: @MainActor () -> Void

    init(
        effects: any SelectedResultActionEffects,
        assistantRunSession: AssistantRunSession,
        runningApplicationActivator: any RunningApplicationActivating,
        recentStore: RecentStore,
        trackSelection: @escaping TrackSelection,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.effects = effects
        self.assistantRunSession = assistantRunSession
        self.runningApplicationActivator = runningApplicationActivator
        self.recentStore = recentStore
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
