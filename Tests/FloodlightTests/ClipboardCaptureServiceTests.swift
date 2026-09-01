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
    var frontmostApplicationBundleIdentifier: String?

    func setContents(
        string: String?,
        types: [NSPasteboard.PasteboardType] = [.string],
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
        frontmostApplicationBundleIdentifier = bundleID
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        stringValues[type]
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
}
