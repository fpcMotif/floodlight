import Foundation
import os

package final class SystemCatalog: Catalog {
    package struct DiscoveredSetting: Equatable, Sendable {
        let name: String
        let keywords: String
        let pane: String
    }

    private struct Setting: Sendable {
        let name: String
        let keywords: String
        let pane: String
        let nameLength: Int
        let titleWordCount: Int
        let normalizedCandidate: String
        let asciiCandidate: [UInt8]?
        let words: [String]
        let characterMask: UInt64
        let url: URL?

        init(name: String, keywords: String, pane: String) {
            self.name = name
            self.keywords = keywords
            self.pane = pane
            let normalizedName = FuzzyMatcher.normalized(name)
            nameLength = normalizedName.count
            titleWordCount = normalizedName
                .split(whereSeparator: { FuzzyMatcher.isSeparatorChar($0) })
                .count
            normalizedCandidate = FuzzyMatcher.normalized("\(name) \(keywords)")
            let bytes = Array(normalizedCandidate.utf8)
            asciiCandidate = bytes.allSatisfy { $0 < 0x80 } ? bytes : nil
            words = normalizedCandidate
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            characterMask = SystemCatalog.characterMask(normalizedCandidate)
            url = URL(string: "x-apple.systempreferences:\(pane)")
        }
    }

    private static let builtInSettings = [
        Setting(
            name: "Accessibility",
            keywords: "voiceover zoom display motor hearing",
            pane: "com.apple.Accessibility-Settings.extension"
        ),
        Setting(
            name: "Appearance",
            keywords: "light dark accent color sidebar icon size",
            pane: "com.apple.Appearance-Settings.extension"
        ),
        Setting(name: "Apple Account", keywords: "icloud account profile", pane: "AppleIDPrefPane"),
        Setting(
            name: "Battery",
            keywords: "energy power low power mode health charging",
            pane: "com.apple.Battery-Settings.extension"
        ),
        Setting(
            name: "Bluetooth",
            keywords: "devices headphones keyboard mouse",
            pane: "com.apple.BluetoothSettings"
        ),
        Setting(
            name: "CDs & DVDs",
            keywords: "disc media optical",
            pane: "com.apple.CD-DVD-Settings.extension"
        ),
        Setting(
            name: "Control Center",
            keywords: "menu bar widgets",
            pane: "com.apple.ControlCenter-Settings.extension"
        ),
        Setting(
            name: "Date & Time",
            keywords: "clock timezone calendar",
            pane: "com.apple.Date-Time-Settings.extension"
        ),
        Setting(
            name: "Desktop & Dock",
            keywords: "wallpaper mission control stage manager dock",
            pane: "com.apple.Desktop-Settings.extension"
        ),
        Setting(
            name: "Displays",
            keywords: "monitor resolution brightness night shift",
            pane: "com.apple.Displays-Settings.extension"
        ),
        Setting(
            name: "Focus",
            keywords: "do not disturb notifications schedule",
            pane: "com.apple.Focus-Settings.extension"
        ),
        Setting(
            name: "General",
            keywords: "about software update storage airdrop handoff login items",
            pane: "com.apple.systempreferences.GeneralSettings"
        ),
        Setting(
            name: "Game Center",
            keywords: "games profile friends multiplayer",
            pane: "com.apple.Game-Center-Settings.extension"
        ),
        Setting(
            name: "Internet Accounts",
            keywords: "mail calendar contacts accounts",
            pane: "com.apple.Internet-Accounts-Settings.extension"
        ),
        Setting(
            name: "Keyboard",
            keywords: "input text shortcuts dictation",
            pane: "com.apple.Keyboard-Settings.extension"
        ),
        Setting(
            name: "Lock Screen",
            keywords: "password screensaver sleep",
            pane: "com.apple.Lock-Screen-Settings.extension"
        ),
        Setting(
            name: "Login Items & Extensions",
            keywords: "startup background extensions",
            pane: "com.apple.LoginItems-Settings.extension"
        ),
        Setting(
            name: "Mouse",
            keywords: "tracking scrolling click",
            pane: "com.apple.Mouse-Settings.extension"
        ),
        Setting(
            name: "Network",
            keywords: "wifi ethernet vpn firewall",
            pane: "com.apple.Network-Settings.extension"
        ),
        Setting(
            name: "Notifications",
            keywords: "alerts focus badges",
            pane: "com.apple.Notifications-Settings.extension"
        ),
        Setting(
            name: "Printers & Scanners",
            keywords: "printer scanner print queue",
            pane: "com.apple.Print-Scan-Settings.extension"
        ),
        Setting(
            name: "Privacy & Security",
            keywords: "location camera microphone full disk access",
            pane: "com.apple.settings.PrivacySecurity.extension"
        ),
        Setting(
            name: "Profiles",
            keywords: "configuration management mdm",
            pane: "com.apple.Profiles-Settings.extension"
        ),
        Setting(
            name: "Screen Saver",
            keywords: "wallpaper lock",
            pane: "com.apple.ScreenSaver-Settings.extension"
        ),
        Setting(
            name: "Screen Time",
            keywords: "app limits downtime content privacy",
            pane: "com.apple.Screen-Time-Settings.extension"
        ),
        Setting(
            name: "Sharing",
            keywords: "computer name screen file media remote login",
            pane: "com.apple.Sharing-Settings.extension"
        ),
        Setting(
            name: "Siri & Spotlight",
            keywords: "assistant search indexing shortcuts",
            pane: "com.apple.Siri-Settings.extension"
        ),
        Setting(
            name: "Software Update",
            keywords: "macos update automatic beta",
            pane: "com.apple.Software-Update-Settings.extension"
        ),
        Setting(
            name: "Sound",
            keywords: "volume output input alert",
            pane: "com.apple.Sound-Settings.extension"
        ),
        Setting(
            name: "Startup Disk",
            keywords: "boot volume disk",
            pane: "com.apple.Startup-Disk-Settings.extension"
        ),
        Setting(
            name: "Storage",
            keywords: "disk space files optimize",
            pane: "com.apple.settings.Storage"
        ),
        Setting(
            name: "Time Machine",
            keywords: "backup restore disk",
            pane: "com.apple.Time-Machine-Settings.extension"
        ),
        Setting(
            name: "Touch ID & Password",
            keywords: "fingerprint authentication login password",
            pane: "com.apple.Touch-ID-Settings.extension"
        ),
        Setting(
            name: "Trackpad",
            keywords: "gestures click scroll",
            pane: "com.apple.Trackpad-Settings.extension"
        ),
        Setting(
            name: "Transfer or Reset",
            keywords: "migration erase reset assistant",
            pane: "com.apple.Transfer-Reset-Settings.extension"
        ),
        Setting(
            name: "Users & Groups",
            keywords: "accounts login password",
            pane: "com.apple.Users-Groups-Settings.extension"
        ),
        Setting(
            name: "Wallet & Apple Pay",
            keywords: "cards payments",
            pane: "com.apple.WalletSettingsExtension"
        ),
        Setting(
            name: "Wallpaper",
            keywords: "desktop background picture",
            pane: "com.apple.Wallpaper-Settings.extension"
        ),
        Setting(
            name: "Wi-Fi",
            keywords: "wifi wireless network hotspot",
            pane: "com.apple.wifi-settings-extension"
        ),
    ]

    private let settings = OSAllocatedUnfairLock(initialState: SystemCatalog.builtInSettings)
    private let refreshGuard = CatalogRefreshGuard()
    private let directoryFingerprint = OSAllocatedUnfairLock(initialState: [String: Date]())
    private let hasStarted = OSAllocatedUnfairLock(initialState: false)
    private let discoveryProvider: @Sendable () -> [DiscoveredSetting]

    package init(
        discoveryProvider: @escaping @Sendable () -> [DiscoveredSetting] = {
            SystemCatalog.discoverInstalledSettings()
        }
    ) {
        self.discoveryProvider = discoveryProvider
    }

    package func start() async throws {
        let shouldDiscover = hasStarted.withLock { started in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldDiscover else { return }
        _ = await refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
    }

    @concurrent
    package func refreshIfNeeded(
        minimumInterval: TimeInterval,
        forceDiscovery: Bool
    ) async -> Bool {
        guard refreshGuard.reserve(minimumInterval: minimumInterval) else { return false }
        defer { refreshGuard.release() }

        let previousFingerprint = directoryFingerprint.withLock { $0 }

        // `@concurrent` is deliberate. Under approachable concurrency, a plain
        // nonisolated async method inherits its caller's actor. These synchronous
        // filesystem walks must leave SourceSearchEngine free to accept a newer
        // query or cancellation, while remaining in the caller's task so its
        // cancellation and priority still apply.
        let fingerprint = Self.makeDirectoryFingerprint(fileManager: .default)
        guard forceDiscovery || fingerprint != previousFingerprint else {
            directoryFingerprint.withLock { $0 = fingerprint }
            return false
        }
        let discovered = discoveryProvider()

        directoryFingerprint.withLock { $0 = fingerprint }

        let installed = discovered.map {
            Setting(name: $0.name, keywords: $0.keywords, pane: $0.pane)
        }
        return settings.withLock { current in
            var knownPanes = Set<String>()
            let replacement = (Self.builtInSettings + installed).filter {
                knownPanes.insert($0.pane).inserted
            }
            let changed = current.map(\.pane) != replacement.map(\.pane)
                || current.map(\.name) != replacement.map(\.name)
                || current.map(\.keywords) != replacement.map(\.keywords)
            current = replacement
            return changed
        }
    }

    private static func makeDirectoryFingerprint(fileManager: FileManager) -> [String: Date] {
        CatalogDirectoryFingerprint.make(
            for: installedSettingsRoots(fileManager: fileManager).map(\.url),
            fileManager: fileManager
        )
    }

    private static func installedSettingsRoots(
        fileManager: FileManager
    ) -> [(url: URL, pathExtension: String, requiresSettingsMarker: Bool)] {
        [
            (
                URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true),
                "appex",
                true
            ),
            (
                URL(
                    fileURLWithPath: "/System/Applications/System Settings.app/Contents/PlugIns",
                    isDirectory: true
                ),
                "appex",
                true
            ),
            (
                URL(fileURLWithPath: "/Library/PreferencePanes", isDirectory: true),
                "prefPane",
                false
            ),
            (
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/PreferencePanes", isDirectory: true),
                "prefPane",
                false
            ),
        ]
    }

    package func immediatePage(for query: String, limit: Int) -> SearchItemPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return SearchItemPage(items: [], totalMatched: 0)
        }
        let normalizedQuery = FuzzyMatcher.normalized(query)
        let queryBytes = Array(normalizedQuery.utf8)
        let asciiQuery = queryBytes.allSatisfy { $0 < 0x80 } ? queryBytes : nil
        let queryCharacterMask = Self.characterMask(normalizedQuery)
        let requiresWordPrefix = normalizedQuery.count < 4
        let snapshot = settings.withLock { $0 }
        let matches = snapshot.compactMap { setting -> SearchItem? in
            guard setting.characterMask & queryCharacterMask == queryCharacterMask else {
                return nil
            }
            guard
                !requiresWordPrefix
                || setting.words.contains(where: { $0.hasPrefix(normalizedQuery) })
            else {
                return nil
            }
            let evidence: FuzzyMatcher.MatchEvidence? = if let asciiQuery,
                                                           let asciiCandidate = setting
                                                           .asciiCandidate
            {
                FuzzyMatcher.matchASCII(
                    normalizedQuery: asciiQuery,
                    normalizedCandidate: asciiCandidate
                )
            } else {
                FuzzyMatcher.match(
                    normalizedQuery: normalizedQuery,
                    normalizedCandidate: setting.normalizedCandidate
                )
            }
            guard let evidence, let url = setting.url else {
                return nil
            }

            let isTitleMatch: Bool = switch evidence.shape {
            case .exact, .namePrefix:
                true
            case let .wordPrefix(offset), let .typo(_, offset):
                offset < setting.nameLength
            case let .acronym(wordIndex):
                wordIndex < setting.titleWordCount
            }

            let subtitle: String
            if isTitleMatch {
                subtitle = "System Settings"
            } else {
                let keyword: String = switch evidence.shape {
                case let .acronym(wordIndex):
                    wordIndex < setting.words.count ? setting.words[wordIndex] : ""
                case let .wordPrefix(offset), let .typo(_, offset):
                    Self.extractMatchedKeyword(
                        from: setting.normalizedCandidate,
                        startingAt: offset
                    )
                case .exact, .namePrefix:
                    ""
                }
                subtitle = keyword.isEmpty ? "System Settings" : "Matches: \(keyword)"
            }

            return SearchItem(
                id: "setting:\(setting.pane)",
                title: setting.name,
                subtitle: subtitle,
                kind: .systemSetting,
                action: .open(url),
                score: SearchItemRanking.setting + evidence.score,
                fileURL: nil
            )
        }

        return SearchItemRanking.page(matches, limit: limit)
    }

    private static func extractMatchedKeyword(
        from candidate: String,
        startingAt offset: Int
    ) -> String {
        let chars = Array(candidate)
        guard offset < chars.count else { return "" }
        var endIndex = offset
        for index in offset..<chars.count {
            if FuzzyMatcher.isSeparatorChar(chars[index]) {
                break
            }
            endIndex = index + 1
        }
        return String(chars[offset..<endIndex])
    }

    private static func characterMask(_ value: String) -> UInt64 {
        value.utf8.reduce(into: 0) { mask, byte in
            let bit: UInt64? = switch byte {
            case 0x61...0x7A:
                UInt64(byte - 0x61)
            case 0x41...0x5A:
                UInt64(byte - 0x41)
            case 0x30...0x39:
                UInt64(byte - 0x30 + 26)
            default:
                nil
            }
            if let bit {
                mask |= 1 << bit
            }
        }
    }

    private static func discoverInstalledSettings() -> [DiscoveredSetting] {
        let fileManager = FileManager.default
        let roots = installedSettingsRoots(fileManager: fileManager)

        var discovered: [DiscoveredSetting] = []
        for root in roots {
            let children = (try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in children
                where url.pathExtension.caseInsensitiveCompare(root.pathExtension) == .orderedSame
            {
                guard
                    let bundle = Bundle(url: url),
                    let identifier = bundle.bundleIdentifier,
                    shouldIndex(
                        bundleIdentifier: identifier,
                        bundleURL: url,
                        requiresSettingsMarker: root.requiresSettingsMarker
                    ),
                    let name = displayName(for: bundle, at: url)
                else {
                    continue
                }

                discovered.append(
                    DiscoveredSetting(
                        name: name,
                        keywords: identifier.replacingOccurrences(
                            of: "[^A-Za-z0-9]+",
                            with: " ",
                            options: .regularExpression
                        ),
                        pane: identifier
                    )
                )
            }
        }
        return discovered
    }

    private static func shouldIndex(
        bundleIdentifier: String,
        bundleURL: URL,
        requiresSettingsMarker: Bool
    ) -> Bool {
        guard requiresSettingsMarker else { return true }
        let candidate = "\(bundleIdentifier) \(bundleURL.deletingPathExtension().lastPathComponent)"
            .lowercased()
        guard candidate.contains("setting") || candidate.contains("preference") else {
            return false
        }
        let excludedMarkers = [
            "diagnostic",
            "deviceexpert",
            "followup",
            "intent",
            "thumbnail",
            "widget",
        ]
        return !excludedMarkers.contains { candidate.contains($0) }
    }

    private static func displayName(for bundle: Bundle, at url: URL) -> String? {
        let values = [
            bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            bundle.localizedInfoDictionary?["CFBundleName"] as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            url.deletingPathExtension().lastPathComponent,
        ]
        guard var name = values.compactMap({ $0 }).first(where: {
            !$0.isEmpty && !$0.hasPrefix("$(")
        }) else {
            return nil
        }

        for suffix in [" Settings Extension", " Settings", " Preferences", " Preference Pane"]
            where name.lowercased().hasSuffix(suffix.lowercased())
        {
            name.removeLast(suffix.count)
            break
        }
        return name.isEmpty ? nil : name
    }
}
