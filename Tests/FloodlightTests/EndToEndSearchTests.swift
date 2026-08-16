import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// End to end: a real directory tree on disk, a real FFF index scanning it,
/// the real `ApplicationCatalog` and `SystemCatalog`, a real `RecentStore`,
/// and the real `SearchCoordinator` on top — no doubles anywhere in the
/// search path.
///
/// Everything else in the suite pins one layer at a time. This is the only
/// place that answers "if a user typed this, would the file come back?",
/// which is the question the whole application exists to answer.
@MainActor
struct EndToEndSearchTests {
    private let tree: TemporaryTree
    private let defaults: IsolatedDefaults
    private let supportURL: URL

    init() throws {
        tree = try TemporaryTree(label: "FloodlightE2E")
        defaults = try IsolatedDefaults(label: "FloodlightE2E")
        supportURL = tree.root.appendingPathComponent(".support", isDirectory: true)

        try tree.makeFile("Documents/quarterly-report.pdf", contents: "%PDF-1.4 quarterly")
        try tree.makeFile("Documents/meeting-notes.txt", contents: "notes about the roadmap")
        try tree.makeFile("Documents/budget.numbers", contents: "budget")
        try tree.makeFile("Pictures/holiday-photo.png", contents: "png")
        try tree.makeFile("Pictures/Ünïcodé-café.jpg", contents: "jpg")
        try tree.makeFile("Code/floodlight/README.md", contents: "Floodlight readme")
        try tree.makeFile("Code/floodlight/main.swift", contents: "print(\"hello\")")
        try tree.makeDirectory("Code/floodlight/Sources")
        try tree.makeDirectory("Archive")
        try tree.makeFile("Archive/solitary-vault/placeholder.dat", contents: "x")
        try tree.makeFile("Downloads/swift-concurrency.epub", contents: "Swift Concurrency eBook")
        try tree.makeFile("Downloads/ghostty-manual.epub", contents: "Ghostty Manual")
    }

    private func makeCoordinator(
        applications: [(name: String, url: URL)] = []
    ) async throws -> SearchCoordinator {
        let recentStore = RecentStore(defaults: defaults.defaults)
        let sourceSearch = SourceSearchEngine(
            rootURL: tree.root,
            storageURL: tree.root.appendingPathComponent(".index", isDirectory: true),
            applications: ApplicationCatalog(
                recentStore: recentStore,
                supportURL: supportURL,
                deferDiscovery: true,
                discoveryProvider: { applications }
            ),
            settings: SystemCatalog(discoveryProvider: { [] })
        )
        let coordinator = SearchCoordinator(
            sourceSearch: sourceSearch,
            recentStore: recentStore,
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: {}
        )

        coordinator.start()
        try await waitUntil("the catalogs finish loading", timeout: 30) {
            coordinator.filterOptions.first { $0.filter == .applications }?.isLoading == false
        }
        return coordinator
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("never became true: \(description)", sourceLocation: sourceLocation)
    }

    /// Types `query` and waits for the indexed pass to deliver a row that
    /// satisfies `predicate`.
    private func search(
        _ coordinator: SearchCoordinator,
        _ query: String,
        forRowMatching predicate: @escaping (SearchItem) -> Bool,
        description: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        coordinator.query = query
        try await waitUntil(description, sourceLocation: sourceLocation) {
            coordinator.results.contains(where: predicate)
        }
    }

    // MARK: - Files come back

    @Test func typingAFileNameReturnsThatFile() async throws {
        let coordinator = try await makeCoordinator()

        try await search(
            coordinator,
            "quarterly",
            forRowMatching: { $0.title.contains("quarterly-report") },
            description: "the quarterly report appears"
        )

        let row = try #require(coordinator.results.first { $0.title.contains("quarterly-report") })
        #expect(row.kind == .file)
        #expect(row.fileURL?.lastPathComponent == "quarterly-report.pdf")
        #expect(row.isPreviewable)
        let quarterlyURL = try #require(row.fileURL)
        #expect(row.action == .open(quarterlyURL))
    }

    @Test func typingAnEpubFileNameReturnsThatBookAndAppearsInDocumentsFilter() async throws {
        let coordinator = try await makeCoordinator()

        try await search(
            coordinator,
            "concurrency",
            forRowMatching: { $0.title.contains("swift-concurrency") },
            description: "the swift concurrency epub appears"
        )

        let row = try #require(coordinator.results.first { $0.title.contains("swift-concurrency") })
        #expect(row.kind == .file)
        #expect(row.fileURL?.lastPathComponent == "swift-concurrency.epub")
        #expect(row.isPreviewable)
        let epubURL = try #require(row.fileURL)
        #expect(row.action == .open(epubURL))

        coordinator.selectFilter(.documents)
        #expect(
            coordinator.results
                .contains { $0.fileURL?.lastPathComponent == "swift-concurrency.epub" },
            "the epub book must appear under the documents filter"
        )
        let documentFilterOption = coordinator.filterOptions.first { $0.filter == .documents }
        #expect(
            documentFilterOption?.count ?? 0 >= 1,
            "document filter count must include epub files"
        )
    }

    @Test func applicationOutranksEpubBookInDownloads() async throws {
        let ghostty = (
            name: "Ghostty",
            url: URL(fileURLWithPath: "/Applications/Ghostty.app", isDirectory: true)
        )
        let coordinator = try await makeCoordinator(applications: [ghostty])

        coordinator.query = "gh"
        try await waitUntil("the search settles for query gh") { !coordinator.isSearching }

        let appIndex = try #require(coordinator.results.firstIndex { $0.kind == .application })
        #expect(appIndex == 0, "the application Ghostty must lead the results")
        let firstResult = try #require(coordinator.results.first)
        #expect(firstResult.kind == .application)
        #expect(firstResult.title == "Ghostty")
    }

    @Test func typingAFolderNameReturnsThatFolder() async throws {
        let coordinator = try await makeCoordinator()

        // A childless folder with a name that appears nowhere else: a
        // folder that contains matching files competes with them for the
        // twelve indexed slots, which makes the assertion about ranking
        // rather than about whether folders are searchable at all.
        try await search(
            coordinator,
            "solitary-vault",
            forRowMatching: { $0.kind == .folder && $0.title.hasPrefix("solitary-vault") },
            description: "the solitary-vault folder appears"
        )

        let row = try #require(coordinator.results
            .first { $0.kind == .folder && $0.title.hasPrefix("solitary-vault") })
        // FFF names directories with a trailing slash and `makeSearchItem`
        // passes the name straight through, so that slash is what a user
        // sees in the panel. Pinned because it is a rendering decision
        // nothing in Floodlight makes explicitly.
        #expect(row.title == "solitary-vault/")
        #expect(!row.isPreviewable, "a folder has nothing to QuickLook")
        #expect(row.fileSize == nil)
    }

    @Test func folderContainingManyMatchingFilesIsStillRecalledAndFiltered() async throws {
        for fileIndex in 0..<20 {
            try tree.makeFile(
                "Projects/project-\(fileIndex).txt",
                contents: "project file \(fileIndex)"
            )
        }
        let coordinator = try await makeCoordinator()

        try await search(
            coordinator,
            "Projects",
            forRowMatching: { $0.kind == .folder && $0.title.hasPrefix("Projects") },
            description: "the Projects folder appears despite matching child files"
        )

        let folderRow = try #require(coordinator.results
            .first { $0.kind == .folder && $0.title.hasPrefix("Projects") })
        #expect(folderRow.title == "Projects/")
        #expect(folderRow.kind == .folder)

        coordinator.selectFilter(.folders)
        #expect(
            coordinator.results.contains { $0.kind == .folder && $0.title.hasPrefix("Projects") },
            "Projects folder must be visible under the folders filter"
        )
    }

    @Test func typingDownloadsWithTrailingSlashReturnsDownloadsFolderAsTopHit() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "Downloads/"
        try await waitUntil("Downloads/ is the Top Hit folder") {
            coordinator.results.first?.kind == .folder
                && coordinator.results.first?.title.hasPrefix("Downloads") == true
        }

        let row = try #require(coordinator.results.first)
        #expect(row.kind == .folder)
        #expect(row.title == "Downloads/")
    }

    @Test func tildePathExpandsAndReturnsHomeOrDownloadsFolder() async throws {
        let coordinator = try await makeCoordinator()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        var isDirectory: ObjCBool = false
        let downloadsExists = FileManager.default.fileExists(
            atPath: downloads.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue

        if downloadsExists {
            coordinator.query = "~/Downloads"
            try await waitUntil("~/Downloads expands to a Downloads folder row") {
                coordinator.results.contains {
                    $0.kind == .folder && $0.title.hasPrefix("Downloads")
                }
            }
            let downloadsRow = try #require(coordinator.results
                .first { $0.kind == .folder && $0.title.hasPrefix("Downloads") })
            #expect(downloadsRow.kind == .folder)
            #expect(downloadsRow.title == "Downloads/")
        }

        coordinator.query = "~/"
        try await waitUntil("~/ expands to a folder row") {
            coordinator.results.contains { $0.kind == .folder }
        }
        let homeRow = try #require(coordinator.results.first { $0.kind == .folder })
        #expect(homeRow.kind == .folder)
    }

    @Test func absoluteApplicationsPathReturnsApplicationsFolder() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "/Applications"
        try await waitUntil("the Applications folder appears") {
            coordinator.results
                .contains { $0.kind == .folder && $0.title.hasPrefix("Applications") }
        }

        let row = try #require(coordinator.results
            .first { $0.kind == .folder && $0.title.hasPrefix("Applications") })
        #expect(row.kind == .folder)
        #expect(row.title == "Applications/")
        #expect(row.fileURL?.standardizedFileURL.path == "/Applications")
    }

    @Test func accentedFileNamesAreFoundByTheirUnaccentedSpelling() async throws {
        // The whole reason `FuzzyMatcher.normalized` exists, proven against
        // a file that is really on disk.
        let coordinator = try await makeCoordinator()

        try await search(
            coordinator,
            "unicode",
            forRowMatching: { $0.kind == .file && $0.title.contains("café") },
            description: "the accented file is found by its plain spelling"
        )
    }

    @Test func dynamicFiltersNarrowRealResultsToTheirFileTypes() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "e"
        try await waitUntil("several files are indexed") {
            coordinator.results.filter { $0.kind == .file }.count >= 2
        }

        coordinator.selectFilter(.pdfs)
        #expect(
            coordinator.results.allSatisfy { $0.fileURL?.pathExtension.lowercased() == "pdf" },
            "the PDF filter admitted a non-PDF"
        )

        coordinator.selectFilter(.images)
        #expect(coordinator.results.allSatisfy {
            ["png", "jpg", "jpeg", "heic"]
                .contains($0.fileURL?.pathExtension.lowercased() ?? "")
        })

        coordinator.selectFilter(.folders)
        #expect(coordinator.results.allSatisfy { $0.kind == .folder })
    }

    @Test func theWebFallbackIsAlwaysAvailableForANonsenseQuery() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "zzzqqqxxx-nothing-matches-this"
        try await waitUntil("the search settles") { !coordinator.isSearching }

        let web = try #require(coordinator.results.first { $0.id == "web-search" })
        #expect(web.kind == .web)
        #expect(coordinator.selectedID == web.id, "the only row is the selected one")
    }

    // MARK: - Applications come back

    @Test func ADiscoveredApplicationIsFoundByName() async throws {
        let orbital = (
            name: "Orbital Launcher",
            url: URL(fileURLWithPath: "/Applications/Orbital Launcher.app", isDirectory: true)
        )
        let coordinator = try await makeCoordinator(applications: [orbital])

        coordinator.query = "orbital"
        try await waitUntil("the application appears") {
            coordinator.results.contains { $0.fileURL == orbital.url }
        }

        let row = try #require(coordinator.results.first { $0.fileURL == orbital.url })
        #expect(row.kind == .application)
        #expect(row.title == "Orbital Launcher")
        #expect(row.id == "application:\(orbital.url.path)")
        #expect(row.score >= SearchItemRanking.application)
    }

    @Test func anApplicationOutranksAFileWithTheSameName() async throws {
        // The band separation, proven end to end rather than by arithmetic:
        // a file named "orbital.txt" must never sit above the app.
        try tree.makeFile("Documents/orbital.txt", contents: "orbital notes")
        let orbital = (
            name: "Orbital",
            url: URL(fileURLWithPath: "/Applications/Orbital.app", isDirectory: true)
        )
        let coordinator = try await makeCoordinator(applications: [orbital])

        coordinator.query = "orbital"
        try await waitUntil("both rows are present") {
            coordinator.results.contains { $0.kind == .application }
                && coordinator.results.contains { $0.kind == .file }
        }

        let appIndex = try #require(coordinator.results.firstIndex { $0.kind == .application })
        let fileIndex = try #require(coordinator.results.firstIndex { $0.kind == .file })
        #expect(appIndex < fileIndex)
    }

    @Test func ghQueryReturnsOnlyGhosttyInTopSlots() async throws {
        let ghostty = (
            name: "Ghostty",
            url: URL(fileURLWithPath: "/Applications/Ghostty.app", isDirectory: true)
        )
        let googleChrome = (
            name: "Google Chrome",
            url: URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        )
        let grapher = (
            name: "Grapher",
            url: URL(
                fileURLWithPath: "/System/Applications/Utilities/Grapher.app",
                isDirectory: true
            )
        )
        let zedNightly = (
            name: "Zed Nightly",
            url: URL(fileURLWithPath: "/Applications/Zed Nightly.app", isDirectory: true)
        )
        let coordinator = try await makeCoordinator(
            applications: [ghostty, googleChrome, grapher, zedNightly]
        )

        coordinator.query = "gh"
        try await waitUntil("the search settles for query gh") { !coordinator.isSearching }

        let appResults = coordinator.results.filter { $0.kind == .application }
        #expect(
            appResults.map(\.title) == ["Ghostty"],
            "Typing 'gh' must return only Ghostty among applications"
        )
        let firstResult = try #require(coordinator.results.first)
        #expect(firstResult.kind == .application)
        #expect(firstResult.title == "Ghostty")
    }

    @Test func safriQueryReturnsSafariViaTypoMatching() async throws {
        let safari = (
            name: "Safari",
            url: URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        )
        let coordinator = try await makeCoordinator(applications: [safari])

        coordinator.query = "safri"
        try await waitUntil("the search settles for query safri") { !coordinator.isSearching }

        let firstResult = try #require(coordinator.results.first)
        #expect(firstResult.kind == .application)
        #expect(firstResult.title == "Safari")
    }

    @Test func loginQueryReturnsZeroApplicationsAndSurfacesSystemSettingsAtTop() async throws {
        let gemini = (
            name: "Gemini",
            url: URL(fileURLWithPath: "/Applications/Gemini.app", isDirectory: true)
        )
        let colorSync = (
            name: "ColorSync Utility",
            url: URL(
                fileURLWithPath: "/System/Applications/Utilities/ColorSync Utility.app",
                isDirectory: true
            )
        )
        let migration = (
            name: "Migration Assistant",
            url: URL(
                fileURLWithPath: "/System/Applications/Utilities/Migration Assistant.app",
                isDirectory: true
            )
        )
        let coordinator = try await makeCoordinator(applications: [gemini, colorSync, migration])

        coordinator.query = "login"
        try await waitUntil("the search settles for query login") { !coordinator.isSearching }

        let appResults = coordinator.results.filter { $0.kind == .application }
        #expect(
            appResults.isEmpty,
            "Typing 'login' must return 0 application results, but got: \(appResults.map(\.title))"
        )
        let firstResult = try #require(coordinator.results.first)
        #expect(firstResult.kind == .systemSetting)
        #expect(firstResult.title == "Login Items & Extensions")
        #expect(firstResult.subtitle == "System Settings")

        let settingResults = coordinator.results.filter { $0.kind == .systemSetting }
        #expect(settingResults.count >= 4)
        for keywordMatch in settingResults.dropFirst() {
            #expect(keywordMatch.subtitle == "Matches: login")
        }
    }

    // MARK: - Cross-cutting rows

    @Test func ACalculatorRowLeadsAnArithmeticQueryOverRealResults() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "12 * 12"
        try await waitUntil("the search settles") { !coordinator.isSearching }

        let first = try #require(coordinator.results.first)
        #expect(first.id == "calculator")
        #expect(first.title == "144")
        #expect(first.action == .copy("144"))
    }

    @Test func AKeywordEngineRowLeadsAnAddressedQuery() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "yt lofi hip hop"
        try await waitUntil("the keyword row appears") {
            coordinator.results.contains { $0.id == "keyword-engine:youtube" }
        }

        let engineIndex = try #require(coordinator.results
            .firstIndex { $0.id == "keyword-engine:youtube" })
        #expect(engineIndex == 0, "an explicitly addressed engine leads the list")
    }

    @Test func settingsCommandsDoNotAppearInSearchResults() async throws {
        let coordinator = try await makeCoordinator()

        for query in [
            "floodlight settings",
            "settings",
            "setup",
            "permissions",
            "shortcut",
            "gh",
            "login",
        ] {
            coordinator.query = query
            try await waitUntil("the search settles for query \(query)") { !coordinator.isSearching
            }

            #expect(
                !(coordinator.results
                    .contains {
                        $0.id.hasPrefix("floodlight-command:") || $0.title == "Floodlight settings"
                    }),
                "Floodlight settings command should never appear in search results for query '\(query)'"
            )
        }
    }

    // MARK: - Re-rooting and rescanning

    @Test func changingTheSearchScopeChangesWhatIsFound() async throws {
        let coordinator = try await makeCoordinator()

        try await search(
            coordinator,
            "quarterly",
            forRowMatching: { $0.title.contains("quarterly-report") },
            description: "the report is visible under the original root"
        )

        // Re-root to a subtree that cannot contain it.
        let archive = tree.root.appendingPathComponent("Archive", isDirectory: true)
        coordinator.changeRoot(to: archive)
        try await waitUntil("the root is adopted", timeout: 30) {
            coordinator.rootURL.standardizedFileURL == archive.standardizedFileURL
        }

        coordinator.query = "quarterly-report"
        try await waitUntil("the search settles") { !coordinator.isSearching }
        try await Task.sleep(for: .milliseconds(400))

        #expect(
            !(coordinator.results
                .contains { $0.kind == .file && $0.title.contains("quarterly-report") }),
            "a file outside the new scope should no longer be found"
        )
    }

    @Test func AFileCreatedAfterStartupIsFoundAfterARescan() async throws {
        let coordinator = try await makeCoordinator()

        try tree.makeFile("Documents/freshly-added-artifact.txt", contents: "new")
        coordinator.rebuildIndex()

        try await search(
            coordinator,
            "freshly-added",
            forRowMatching: { $0.title.contains("freshly-added-artifact") },
            description: "a newly created file is found after a rebuild"
        )
    }

    // MARK: - Stress

    @Test func theFullPipelineSurvivesAFloodOfRealQueries() async throws {
        // Every adversarial query, typed back to back against the real
        // index. Nothing may trap, hang, or leave the panel incoherent.
        let coordinator = try await makeCoordinator()

        for query in AdversarialCorpus.searchQueries + AdversarialCorpus.strings {
            coordinator.query = query
            let ids = coordinator.results.map(\.id)
            #expect(ids.count == Set(ids).count, "\(String(reflecting: query))")
            #expect(coordinator.results.count <= 80, "\(String(reflecting: query))")
            if !coordinator.results.isEmpty {
                #expect(coordinator.selectedID != nil, "\(String(reflecting: query))")
            }
        }

        coordinator.query = "quarterly"
        try await waitUntil("the pipeline still works after the flood", timeout: 20) {
            coordinator.results.contains { $0.title.contains("quarterly-report") }
        }
    }

    @Test func AWideTreeIsIndexedAndSearchableWithinBudget() async throws {
        // Two thousand files is a small home directory, and the first
        // keystroke after startup still has to be answered promptly.
        for directory in 0..<20 {
            for file in 0..<100 {
                try tree.makeFile(
                    "Bulk/dir-\(directory)/bulk-file-\(directory)-\(file).txt",
                    contents: "bulk"
                )
            }
        }
        let coordinator = try await makeCoordinator()

        let start = ContinuousClock.now
        coordinator.query = "bulk-file-7-42"
        let immediateElapsed = start.duration(to: .now)
        #expect(
            immediateElapsed < .milliseconds(250),
            "the immediate pass must never block on the index"
        )

        try await waitUntil("the bulk file is found", timeout: 30) {
            coordinator.results.contains { $0.title == "bulk-file-7-42.txt" }
        }
    }

    @Test func repeatedResetAndRetypeLeavesNoResidue() async throws {
        let coordinator = try await makeCoordinator()

        for _ in 0..<25 {
            coordinator.query = "quarterly"
            coordinator.reset()
            #expect(coordinator.results.isEmpty)
            #expect(coordinator.selectedID == nil)
            #expect(coordinator.selectedFilter == .all)
        }

        try await search(
            coordinator,
            "quarterly",
            forRowMatching: { $0.title.contains("quarterly-report") },
            description: "the pipeline still works after repeated resets"
        )
    }
}
