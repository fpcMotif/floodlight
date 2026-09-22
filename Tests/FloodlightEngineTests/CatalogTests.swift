import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

private final class ApplicationDiscoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var applications: [(name: String, url: URL)]

    init(_ applications: [(name: String, url: URL)]) {
        self.applications = applications
    }

    func snapshot() -> [(name: String, url: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return applications
    }

    func replace(with applications: [(name: String, url: URL)]) {
        lock.lock()
        self.applications = applications
        lock.unlock()
    }
}

private final class BlockingApplicationDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func snapshot() -> [(name: String, url: URL)] {
        lock.lock()
        calls += 1
        lock.unlock()
        started.signal()
        release.wait()
        return []
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        started.wait(timeout: .now() + TestBudget.seconds(timeout)) == .success
    }

    func resume(count: Int = 1) {
        for _ in 0..<count {
            release.signal()
        }
    }
}

private final class CatalogTestSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func send() {
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + TestBudget.seconds(timeout)) == .success
    }
}

private final class SystemSettingsDiscoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: [SystemCatalog.DiscoveredSetting]

    init(_ settings: [SystemCatalog.DiscoveredSetting]) {
        self.settings = settings
    }

    func snapshot() -> [SystemCatalog.DiscoveredSetting] {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func replace(with settings: [SystemCatalog.DiscoveredSetting]) {
        lock.lock()
        self.settings = settings
        lock.unlock()
    }
}

struct CatalogTests {
    @Test func discoversFinderAndUserFacingCoreServicesApplications() throws {
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        guard FileManager.default.fileExists(atPath: finderURL.path) else {
            try Test.cancel("Finder is not installed at the standard path.")
        }

        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults)
        )

        let finder = catalog.immediatePage(for: "finder").items
        #expect(finder.contains { $0.fileURL == finderURL })

        let archiveUtilityURL = URL(
            fileURLWithPath: "/System/Library/CoreServices/Applications/Archive Utility.app"
        )
        if FileManager.default.fileExists(atPath: archiveUtilityURL.path) {
            let archiveUtility = catalog.immediatePage(for: "archive utility").items
            #expect(archiveUtility.contains { $0.fileURL == archiveUtilityURL })
        }

        let dockAgentURL = URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app")
        #expect(!(catalog.immediatePage(for: "dock").items
                .contains { $0.fileURL == dockAgentURL }))
    }

    @Test func blocklistExcludesApplicationFromImmediateAndIndexedResults() throws {
        let suiteName = "FloodlightBlocklistCatalogTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let blocklist = BlocklistStore(defaults: defaults)
        blocklist.block(name: "Clash")

        let discovery = ApplicationDiscoveryFixture([
            (name: "Claude", url: URL(fileURLWithPath: "/Applications/Claude.app")),
            (name: "Clash", url: URL(fileURLWithPath: "/Applications/Clash.app")),
        ])

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: blocklist,
            discoveryProvider: { discovery.snapshot() }
        )

        let immediate = catalog.immediatePage(for: "cl").items
        #expect(immediate.contains { $0.title == "Claude" })
        #expect(!immediate.contains { $0.title == "Clash" })
        #expect(catalog.immediatePage(for: "clash").items.isEmpty)
    }

    /// One retrieval mechanism: the in-memory snapshot is the whole answer,
    /// so the protocol's default indexed contribution must stay empty even
    /// when the snapshot holds eligible matches.
    @Test func applicationIndexedContributionIsEmpty() async throws {
        let suiteName = "FloodlightSingleMechanismTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let claude = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: BlocklistStore(defaults: defaults),
            deferDiscovery: true,
            discoveryProvider: { [(name: "Claude", url: claude)] }
        )
        try await catalog.start()

        #expect(catalog.immediatePage(for: "claude").items.contains { $0.fileURL == claude })
        #expect(try await catalog.indexedItems(for: "claude", limit: 80).isEmpty)
    }

    /// #100 acceptance: a fresh catalog startup must create no marker files or
    /// application FFF databases — the strongest form leaves the support
    /// directory itself uncreated.
    @Test func startupLeavesSupportDirectoryFreeOfApplicationIndexArtifacts() async throws {
        let suiteName = "FloodlightCatalogArtifactsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let supportURL = TemporaryDirectory.make(label: "FloodlightCatalogSupport")
        defer { try? FileManager.default.removeItem(at: supportURL) }

        let claude = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
        let catalog = ApplicationCatalog(
            supportURL: supportURL,
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: BlocklistStore(defaults: defaults),
            deferDiscovery: true,
            discoveryProvider: { [(name: "Claude", url: claude)] }
        )
        try await catalog.start()

        #expect(catalog.immediatePage(for: "claude").items.contains { $0.fileURL == claude })
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }

    /// #100 acceptance: upgrading machines still carry the marker tree and the
    /// private FFF databases that earlier builds wrote under the support
    /// directory; search must work without touching a byte of that storage.
    @Test func legacyApplicationIndexArtifactsStayUntouched() async throws {
        let suiteName = "FloodlightCatalogLegacyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let supportURL = TemporaryDirectory.make(label: "FloodlightCatalogLegacy")
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let itemsURL = supportURL
            .appendingPathComponent("ApplicationIndex/Items", isDirectory: true)
        let databaseURL = supportURL
            .appendingPathComponent("ApplicationIndex/Database", isDirectory: true)
        try FileManager.default.createDirectory(at: itemsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        let artifacts = [
            itemsURL.appendingPathComponent("Claude.app"),
            itemsURL.appendingPathComponent("Café.app"),
            databaseURL.appendingPathComponent("frecency.lmdb"),
            databaseURL.appendingPathComponent("history.lmdb"),
        ]
        for (index, artifact) in artifacts.enumerated() {
            try Data("legacy-\(index)".utf8).write(to: artifact)
        }
        let contentsBefore = try artifacts.map { try Data(contentsOf: $0) }
        let listingBefore = try FileManager.default
            .subpathsOfDirectory(atPath: supportURL.path).sorted()

        let claude = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
        let catalog = ApplicationCatalog(
            supportURL: supportURL,
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: BlocklistStore(defaults: defaults),
            deferDiscovery: true,
            discoveryProvider: { [(name: "Claude", url: claude)] }
        )
        try await catalog.start()
        _ = try await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        #expect(catalog.immediatePage(for: "claude").items.contains { $0.fileURL == claude })
        #expect(try artifacts.map { try Data(contentsOf: $0) } == contentsBefore)
        #expect(
            try FileManager.default.subpathsOfDirectory(atPath: supportURL.path).sorted()
                == listingBefore
        )
    }

    @Test func blocklistNameRulesMatchRegardlessOfCaseAndDiacritics() throws {
        let suiteName = "FloodlightBlocklistFoldingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let blocklist = BlocklistStore(defaults: defaults)
        blocklist.block(name: "CLÁSH")

        let discovery = ApplicationDiscoveryFixture([
            (name: "Claude", url: URL(fileURLWithPath: "/Applications/Claude.app")),
            (name: "Clash", url: URL(fileURLWithPath: "/Applications/Clash.app")),
        ])

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: blocklist,
            discoveryProvider: { discovery.snapshot() }
        )

        let immediate = catalog.immediatePage(for: "cl").items
        #expect(immediate.contains { $0.title == "Claude" })
        #expect(!immediate.contains { $0.title == "Clash" })
    }

    @Test func discoversSymlinkedSystemApplications() async throws {
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safariURL.path) else {
            try Test.cancel("Safari is not installed at the standard path.")
        }

        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults)
        )
        try await catalog.start()
        let results = catalog.immediatePage(for: "safari").items
        #expect(results.contains { $0.fileURL?.lastPathComponent == "Safari.app" })
        #expect(results.filter { $0.fileURL?.lastPathComponent == "Safari.app" }.count == 1)
    }

    @Test func systemSettingsAvoidLooseShortSubsequences() {
        let catalog = SystemCatalog()
        #expect(catalog.immediatePage(for: "arc").items.isEmpty)
        #expect(catalog.immediatePage(for: "bluetooth").items.first?.title == "Bluetooth")
    }

    @Test func systemSettingsSurfacesKeywordMatchReasonInSubtitle() {
        let catalog = SystemCatalog()

        let bluetooth = catalog.immediatePage(for: "bluetooth").items
        #expect(bluetooth.first?.title == "Bluetooth")
        #expect(bluetooth.first?.subtitle == "System Settings")

        let loginItems = catalog.immediatePage(for: "login").items
        #expect(!(loginItems.isEmpty))
        #expect(loginItems.first?.title == "Login Items & Extensions")
        #expect(loginItems.first?.subtitle == "System Settings")

        let keywordMatches = loginItems.dropFirst()
        #expect(!(keywordMatches.isEmpty))
        for match in keywordMatches {
            #expect(
                match.subtitle == "Matches: login",
                "Setting \(match.title) matched on keyword 'login' but had subtitle \(match.subtitle)"
            )
        }

        let airdrop = catalog.immediatePage(for: "airdrop").items
        #expect(airdrop.first?.title == "General")
        #expect(airdrop.first?.subtitle == "Matches: airdrop")

        let vpn = catalog.immediatePage(for: "vpn").items
        #expect(vpn.first?.title == "Network")
        #expect(vpn.first?.subtitle == "Matches: vpn")

        let camera = catalog.immediatePage(for: "camera").items
        #expect(camera.first?.title == "Privacy & Security")
        #expect(camera.first?.subtitle == "Matches: camera")
    }

    @Test func applicationSearchRespondsWithinBudget() throws {
        let suiteName = "FloodlightTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults)
        )
        let start = ContinuousClock.now
        let page = catalog.immediatePage(for: "claude")
        let elapsed = start.duration(to: .now)

        #expect(elapsed < TestBudget.duration(.milliseconds(100)))
        #expect(page.totalMatched >= page.items.count)
        if FileManager.default.fileExists(atPath: "/Applications/Claude.app") {
            #expect(page.items.first?.fileURL?.lastPathComponent == "Claude.app")
        }
    }

    /// The regression issue #69 documented: a substitution typo introduces a
    /// letter the candidate does not have, and the removed character-mask
    /// prefilter rejected such candidates before the structural matcher — and
    /// its edit budget — ever saw them. Nothing may sit in front of the
    /// matcher again.
    @Test func substitutionTypoWithNovelLetterReachesTheApplication() throws {
        let suiteName = "FloodlightSubstitutionTypoTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let nebula = (
            name: "Nebula",
            url: URL(fileURLWithPath: "/Applications/Nebula.app", isDirectory: true)
        )
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            discoveryProvider: { [nebula] }
        )

        let page = catalog.immediatePage(for: "nebulx")
        #expect(page.items.first?.fileURL == nebula.url)
        #expect(page.totalMatched == 1)
    }

    // MARK: - Source Selection Learning

    /// Someone types the start of the name they mean. Whatever else they open
    /// all day, the app they typed the start of comes first — a correction is
    /// what the ranking falls back to, never what it prefers.
    @Test func aSaturatedTypoMatchStaysBelowAnUnlaunchedNamePrefixMatch() throws {
        let suiteName = "FloodlightLearningPrefixTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // "disc" reaches Discord by name prefix and Disk Cleaner only by
        // correcting the "c" to a "k".
        let discord = Self.application(named: "Discord")
        let diskCleaner = Self.application(named: "Disk Cleaner")

        let recentStore = RecentStore(defaults: defaults)
        Self.saturateLaunches(of: Self.identifier(of: diskCleaner), in: recentStore)

        let catalog = ApplicationCatalog(
            recentStore: recentStore,
            discoveryProvider: { [discord, diskCleaner] }
        )

        #expect(catalog.immediatePage(for: "disc").items.map(\.title)
            == ["Discord", "Disk Cleaner"])
    }

    /// The same rule one shape down: a word prefix is still something the
    /// person typed, so it outranks a correction however hot the correction is.
    @Test func aSaturatedTypoMatchStaysBelowAnUnlaunchedWordPrefixMatch() throws {
        let suiteName = "FloodlightLearningWordPrefixTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let googleChrome = Self.application(named: "Google Chrome")
        let chromaEditor = Self.application(named: "Chroma Editor")

        let recentStore = RecentStore(defaults: defaults)
        Self.saturateLaunches(of: Self.identifier(of: chromaEditor), in: recentStore)

        let catalog = ApplicationCatalog(
            recentStore: recentStore,
            discoveryProvider: { [googleChrome, chromaEditor] }
        )

        #expect(catalog.immediatePage(for: "chrome").items.map(\.title)
            == ["Google Chrome", "Chroma Editor"])
    }

    /// Learning is confined, not cancelled: among results that matched the
    /// same way it still decides the order, and visibly so.
    @Test func applicationsThatMatchedTheSameWayAreOrderedByLaunchHistory() throws {
        let suiteName = "FloodlightLearningSameShapeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // "not" is a name prefix of both, so nothing but learning separates
        // them.
        let notes = Self.application(named: "Notes")
        let notion = Self.application(named: "Notion")

        let recentStore = RecentStore(defaults: defaults)
        let catalog = ApplicationCatalog(
            recentStore: recentStore,
            discoveryProvider: { [notes, notion] }
        )

        #expect(catalog.immediatePage(for: "not").items.map(\.title) == ["Notes", "Notion"])

        Self.saturateLaunches(of: Self.identifier(of: notion), in: recentStore)

        #expect(catalog.immediatePage(for: "not").items.map(\.title) == ["Notion", "Notes"])
    }

    /// Upgrading must not reset personalization: a catalog recreated over the
    /// same RecentStore — what happens across app launches — awards the same
    /// boost and returns the same order.
    @Test func launchHistoryIsRetainedAcrossCatalogRecreation() throws {
        let suiteName = "FloodlightLearningRetentionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notes = Self.application(named: "Notes")
        let notion = Self.application(named: "Notion")

        let recentStore = RecentStore(defaults: defaults)
        Self.saturateLaunches(of: Self.identifier(of: notion), in: recentStore)

        let first = ApplicationCatalog(
            recentStore: recentStore,
            discoveryProvider: { [notes, notion] }
        )
        let second = ApplicationCatalog(
            recentStore: recentStore,
            discoveryProvider: { [notes, notion] }
        )

        let firstPage = first.immediatePage(for: "not")
        let secondPage = second.immediatePage(for: "not")
        #expect(firstPage.items.map(\.title) == ["Notion", "Notes"])
        #expect(secondPage.items == firstPage.items)
        #expect(secondPage.totalMatched == firstPage.totalMatched)
    }

    private static func application(named name: String) -> (name: String, url: URL) {
        (
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
        )
    }

    /// Mirrors the identifier `ApplicationCatalog` derives for a discovered app,
    /// which is the key learning is recorded under.
    private static func identifier(of application: (name: String, url: URL)) -> String {
        "application:\(application.url.path)"
    }

    /// Drives `id` to the largest launch history the store will award.
    ///
    /// `record` returns before the entry is readable, so this polls rather
    /// than assuming the writes have landed.
    private static func saturateLaunches(
        of id: String,
        in store: RecentStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for _ in 0..<25 {
            store.record(id)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if store.boost(for: id) == FuzzyMatcher.maximumLearningBoost { return }
            usleep(2_000)
        }
        Issue.record(
            "launch history never saturated for \(id)",
            sourceLocation: sourceLocation
        )
    }

    /// Selection tracking for applications is the protocol's no-op: learning
    /// comes from RecentStore alone, so reporting a selection must neither
    /// create results nor reorder them.
    @Test func selectionTrackingDoesNotChangeApplicationResults() async throws {
        let suiteName = "FloodlightTrackingNoOpTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gemini = (
            name: "Gemini",
            url: URL(fileURLWithPath: "/Applications/Gemini.app", isDirectory: true)
        )
        let migration = (
            name: "Migration Assistant",
            url: URL(
                fileURLWithPath: "/System/Applications/Utilities/Migration Assistant.app",
                isDirectory: true
            )
        )
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            deferDiscovery: true,
            discoveryProvider: { [gemini, migration] }
        )
        try await catalog.start()

        let before = catalog.immediatePage(for: "migration")
        catalog.track(query: "migration", selectedURL: gemini.url)
        catalog.track(query: "login", selectedURL: migration.url)
        let after = catalog.immediatePage(for: "migration")

        #expect(after.items == before.items)
        #expect(after.totalMatched == before.totalMatched)
        #expect(catalog.immediatePage(for: "login").items.isEmpty)
    }

    @Test func refreshTracksApplicationInstallRenameAndRemovalAfterStartup() async throws {
        let suiteName = "FloodlightRefreshTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notes = (
            name: "Notes",
            url: URL(fileURLWithPath: "/Applications/Notes.app", isDirectory: true)
        )
        let raycast = (
            name: "Raycast",
            url: URL(fileURLWithPath: "/Applications/Raycast.app", isDirectory: true)
        )
        let discovery = ApplicationDiscoveryFixture([notes])
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            deferDiscovery: true,
            discoveryProvider: { discovery.snapshot() }
        )

        try await catalog.start()
        #expect(catalog.immediatePage(for: "raycast").items.isEmpty)

        discovery.replace(with: [notes, raycast])
        let didAddRaycast = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        #expect(didAddRaycast)
        #expect(catalog.immediatePage(for: "raycast").items.first?.fileURL == raycast.url)

        let orbital = (
            name: "Orbital Launcher",
            url: URL(fileURLWithPath: "/Applications/Orbital Launcher.app", isDirectory: true)
        )
        discovery.replace(with: [notes, orbital])
        let didRenameRaycast = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        #expect(didRenameRaycast)
        #expect(!(catalog.immediatePage(for: "raycast").items
                .contains { $0.fileURL == raycast.url }))
        #expect(catalog.immediatePage(for: "orbital launcher").items.first?.fileURL == orbital.url)

        discovery.replace(with: [notes])
        let didRemoveOrbital = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        #expect(didRemoveOrbital)
        #expect(!(catalog.immediatePage(for: "orbital launcher").items
                .contains { $0.fileURL == orbital.url }))

        let didChangeAgain = try await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        #expect(!didChangeAgain)
    }

    @Test func applicationRefreshIsSingleFlight() async throws {
        let suiteName = "FloodlightSingleFlightTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let discovery = BlockingApplicationDiscovery()
        defer { discovery.resume(count: 2) }
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            deferDiscovery: true,
            discoveryProvider: { discovery.snapshot() }
        )
        let firstRefresh = Task {
            try await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        }

        let firstStarted = await Task.detached {
            discovery.waitUntilStarted(timeout: 2)
        }.value
        guard firstStarted else {
            firstRefresh.cancel()
            Issue.record("the first forced discovery did not start")
            return
        }

        let secondFinished = CatalogTestSignal()
        let secondRefresh = Task {
            let result = try? await catalog.refreshIfNeeded(
                minimumInterval: 0,
                forceDiscovery: true
            )
            secondFinished.send()
            return result
        }
        let secondReturned = await Task.detached {
            secondFinished.wait(timeout: 2)
        }.value
        guard secondReturned else {
            discovery.resume(count: 2)
            _ = try? await firstRefresh.value
            _ = await secondRefresh.value
            Issue.record("a concurrent refresh queued behind the active discovery")
            return
        }

        let secondResult = await secondRefresh.value
        #expect(secondResult == false)
        #expect(discovery.callCount == 1)

        discovery.resume()
        _ = try await firstRefresh.value
        #expect(discovery.callCount == 1)
    }

    @Test func indexesInstalledSystemSettings() async throws {
        let catalog = SystemCatalog()
        try await catalog.start()

        let appearance = catalog.immediatePage(for: "appearance", limit: 24)
        let wifi = catalog.immediatePage(for: "wifi", limit: 24)

        #expect(appearance.items.contains { $0.title == "Appearance" })
        #expect(wifi.items.contains { $0.title == "Wi-Fi" || $0.title == "Network" })
        #expect(appearance.totalMatched >= appearance.items.count)
    }

    @Test func systemSettingsRefreshTracksInstallRenameAndRemoval() async {
        let pane = "com.floodlight.tests.dynamic-settings"
        let aurora = SystemCatalog.DiscoveredSetting(
            name: "Aurora Controls",
            keywords: "floodlight dynamic fixture",
            pane: pane
        )
        let discovery = SystemSettingsDiscoveryFixture([aurora])
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })

        let didInstall = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        #expect(didInstall)
        #expect(catalog.immediatePage(for: "Aurora Controls").items.first?.id == "setting:\(pane)")

        let nebula = SystemCatalog.DiscoveredSetting(
            name: "Nebula Controls",
            keywords: "floodlight renamed fixture",
            pane: pane
        )
        discovery.replace(with: [nebula])
        let didRename = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        #expect(didRename)
        #expect(!(catalog.immediatePage(for: "Aurora Controls").items
                .contains { $0.id == "setting:\(pane)" }))
        #expect(catalog.immediatePage(for: "Nebula Controls").items.first?.id == "setting:\(pane)")

        discovery.replace(with: [])
        let didRemove = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        #expect(didRemove)
        #expect(!(catalog.immediatePage(for: "Nebula Controls").items
                .contains { $0.id == "setting:\(pane)" }))
    }
}
