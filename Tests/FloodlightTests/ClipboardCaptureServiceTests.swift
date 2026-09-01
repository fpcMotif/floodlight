import AppKit
import FloodlightEngine
import Foundation
import Testing
@testable import Floodlight

@MainActor
final class ScriptedPasteboardObserver: PasteboardObserving {
    var changeCount: Int = 0
    var pasteboardTypes: [NSPasteboard.PasteboardType]?
    var stringValues: [NSPasteboard.PasteboardType: String] = [:]
    var capturedFilePaths: [String] = []
    var frontmostApplicationBundleIdentifier: String?

    func setContents(
        string: String?,
        types: [NSPasteboard.PasteboardType] = [.string],
        filePaths: [String] = [],
        bundleID: String? = nil,
        bumpChangeCount: Bool = true
    ) {
        if bumpChangeCount {
            changeCount += 1
        }
        pasteboardTypes = types
        stringValues.removeAll()
        if let string {
            stringValues[.string] = string
        }
        capturedFilePaths = filePaths
        frontmostApplicationBundleIdentifier = bundleID
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        stringValues[type]
    }

    func filePaths() -> [String] {
        capturedFilePaths
    }
}

@MainActor
struct ClipboardCaptureServiceTests {
    private struct Harness {
        let service: ClipboardCaptureService
        let store: ClipboardHistoryStore
        let observer: ScriptedPasteboardObserver
        let exclusions: ClipboardExclusionStore
    }

    private func makeHarness(
        initialText: String? = nil,
        excludedBundleIDs: [String] = []
    ) -> Harness {
        let store = ClipboardHistoryStore.inMemory()
        let observer = ScriptedPasteboardObserver()
        if let initialText {
            observer.setContents(string: initialText)
        }
        let defaults = UserDefaults(suiteName: "test-exclusions-\(UUID().uuidString)")!
        let exclusions = ClipboardExclusionStore(defaults: defaults)
        for bundleID in excludedBundleIDs {
            exclusions.exclude(bundleID: bundleID)
        }
        let service = ClipboardCaptureService(
            store: store,
            observer: observer,
            exclusions: exclusions,
            defaults: defaults
        )
        return Harness(
            service: service,
            store: store,
            observer: observer,
            exclusions: exclusions
        )
    }

    @Test func pollDoesNothingWhenChangeCountIsUnchanged() {
        let harness = makeHarness(initialText: "Initial content")
        // Service starts initialized to observer's current changeCount
        harness.service.poll()

        #expect(harness.store.isEmpty)
    }

    @Test func pollRecordsNormalCopy() {
        let harness = makeHarness()

        harness.observer.setContents(string: "Copied from Notes", bundleID: "com.apple.Notes")
        harness.service.poll()

        #expect(harness.store.count == 1)
        let entry = harness.store.mostRecentEntry
        #expect(entry?.text == "Copied from Notes")
        #expect(entry?.sourceAppBundleID == "com.apple.Notes")
    }

    @Test func pollSkipsOwnWriteMarkerType() {
        let harness = makeHarness()

        harness.observer.setContents(
            string: "Floodlight activation copy",
            types: [.string, .floodlightOwnWrite]
        )
        harness.service.poll()

        #expect(harness.store.isEmpty, "own-write copies must not enter history")
    }

    @Test func pollSkipsConcealedTransientAndSensitiveTypes() {
        let harness = makeHarness()

        // ConcealedType (password managers)
        harness.observer.setContents(
            string: "super-secret-password-1",
            types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]
        )
        harness.service.poll()
        #expect(harness.store.isEmpty)

        // TransientType
        harness.observer.setContents(
            string: "super-secret-password-2",
            types: [.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")]
        )
        harness.service.poll()
        #expect(harness.store.isEmpty)

        // com.apple.is-sensitive
        harness.observer.setContents(
            string: "super-secret-password-3",
            types: [.string, NSPasteboard.PasteboardType("com.apple.is-sensitive")]
        )
        harness.service.poll()
        #expect(harness.store.isEmpty)
    }

    @Test func pollSkipsExcludedApplication() {
        let harness = makeHarness(excludedBundleIDs: ["com.1password.1password"])

        harness.observer.setContents(
            string: "Excluded app content",
            bundleID: "com.1password.1password"
        )
        harness.service.poll()

        #expect(harness.store.isEmpty, "content from excluded bundle ID must be skipped")

        // Allowed app still records
        harness.observer.setContents(
            string: "Allowed app content",
            bundleID: "com.apple.Safari"
        )
        harness.service.poll()
        #expect(harness.store.count == 1)
        #expect(harness.store.mostRecentEntry?.text == "Allowed app content")
    }

    @Test func pollSkipsOversizedText() {
        let harness = makeHarness()
        let huge = String(repeating: "x", count: 32_001)

        harness.observer.setContents(string: huge)
        harness.service.poll()

        #expect(harness.store.isEmpty)
    }

    @Test func pollCollapsesConsecutiveDuplicates() {
        let harness = makeHarness()

        harness.observer.setContents(string: "Same copy")
        harness.service.poll()
        #expect(harness.store.count == 1)

        // Same text with bumped changeCount
        harness.observer.setContents(string: "Same copy")
        harness.service.poll()
        #expect(harness.store.count == 1)
    }

    @Test func sessionResignPausesAndResumeReBaselinesChangeCount() {
        let harness = makeHarness()

        harness.service.pause()

        // Copy happened while session was inactive
        harness.observer.setContents(string: "Inactive session copy")
        harness.service.poll()
        #expect(harness.store.isEmpty, "paused service must not record")

        // Resume re-baselines changeCount
        harness.service.resume()
        harness.service.poll()
        #expect(harness.store.isEmpty, "copies made while inactive must not be recorded on resume")

        // Next copy after resume records normally
        harness.observer.setContents(string: "Active copy")
        harness.service.poll()
        #expect(harness.store.count == 1)
        #expect(harness.store.mostRecentEntry?.text == "Active copy")
    }

    @Test func pollRecordsCopiedFileReferencesAsFileEntries() {
        let harness = makeHarness()
        let path = "/Users/f/Documents/Invoices/Invoice_2026.pdf"

        harness.observer.setContents(
            string: path,
            types: [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")],
            filePaths: [path],
            bundleID: "com.apple.finder"
        )
        harness.service.poll()

        #expect(harness.store.count == 1)
        let entry = harness.store.mostRecentEntry
        #expect(entry?.kind == .file)
        #expect(entry?.text == path)
        #expect(entry?.sourceAppBundleID == "com.apple.finder")
    }

    @Test func pollCanonicalizesFileURLsAndRelativePaths() {
        let harness = makeHarness()

        harness.observer.setContents(
            string: nil,
            types: [.fileURL],
            filePaths: ["file:///Users/f/Movies/ProductDemo_4K.mov"]
        )
        harness.service.poll()

        #expect(harness.store.mostRecentEntry?.kind == .file)
        #expect(harness.store.mostRecentEntry?.text == "/Users/f/Movies/ProductDemo_4K.mov")
    }

    @Test func pollRecordsEachCopiedFileAsItsOwnEntry() {
        let harness = makeHarness()

        harness.observer.setContents(
            string: nil,
            types: [NSPasteboard.PasteboardType("NSFilenamesPboardType")],
            filePaths: [
                "/Users/f/Documents/Invoice_2026.pdf",
                "/Users/f/devv/floodlight",
            ]
        )
        harness.service.poll()

        #expect(harness.store.count == 2)
        #expect(harness.store.search(query: "").map(\.text) == [
            "/Users/f/devv/floodlight",
            "/Users/f/Documents/Invoice_2026.pdf",
        ])
        #expect(harness.store.search(query: "").allSatisfy { $0.kind == .file })
    }

    @Test func pollPrefersFileReferencesOverPlainTextWhenBothArePresent() {
        let harness = makeHarness()
        let path = "/Users/f/Documents/Invoice_2026.pdf"

        harness.observer.setContents(
            string: path,
            types: [.string, .fileURL],
            filePaths: [path]
        )
        harness.service.poll()

        #expect(harness.store.count == 1)
        #expect(harness.store.mostRecentEntry?.kind == .file)
        #expect(harness.store.mostRecentEntry?.text == path)
    }

    @Test func pollSkipsOwnWriteAndExcludedAppsForFileCopies() {
        let harness = makeHarness(excludedBundleIDs: ["com.1password.1password"])
        let path = "/Users/f/secret.pdf"

        harness.observer.setContents(
            string: nil,
            types: [.fileURL, .floodlightOwnWrite],
            filePaths: [path]
        )
        harness.service.poll()
        #expect(harness.store.isEmpty)

        harness.observer.setContents(
            string: nil,
            types: [.fileURL],
            filePaths: [path],
            bundleID: "com.1password.1password"
        )
        harness.service.poll()
        #expect(harness.store.isEmpty)
    }
}
