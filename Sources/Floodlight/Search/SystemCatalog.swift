import Foundation
import os

enum SystemCatalog {
    private struct Setting: Sendable {
        let name: String
        let keywords: String
        let pane: String
        let normalizedCandidate: String
        let words: [String]
        let url: URL?

        init(name: String, keywords: String, pane: String) {
            self.name = name
            self.keywords = keywords
            self.pane = pane
            normalizedCandidate = FuzzyMatcher.normalized("\(name) \(keywords)")
            words = normalizedCandidate
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
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

    private static let settings = OSAllocatedUnfairLock(initialState: builtInSettings)
    private static let discoveryStarted = OSAllocatedUnfairLock(initialState: false)

    static func start() async {
        let shouldDiscover = discoveryStarted.withLock { started in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldDiscover else { return }

        let discovered = await Task.detached(priority: .utility) {
            discoverInstalledSettings()
        }.value

        settings.withLock { current in
            var knownPanes = Set(current.map(\.pane))
            current.append(contentsOf: discovered.filter { knownPanes.insert($0.pane).inserted })
        }
    }

    static func search(_ query: String, limit: Int = 6) -> [SearchItem] {
        searchPage(query, limit: limit).items
    }

    static func searchPage(_ query: String, limit: Int = 6) -> SearchItemPage {
        guard !query.isEmpty else {
            return SearchItemPage(items: [], totalMatched: 0)
        }
        let normalizedQuery = FuzzyMatcher.normalized(query)
        let snapshot = settings.withLock { $0 }
        let matches = snapshot.compactMap { setting -> SearchItem? in
            let hasWordPrefix = setting.words.contains { $0.hasPrefix(normalizedQuery) }
            guard let score = FuzzyMatcher.score(
                normalizedQuery: normalizedQuery,
                normalizedCandidate: setting.normalizedCandidate
            ),
                  normalizedQuery.count >= 4 || hasWordPrefix,
                  score >= 9_000,
                  let url = setting.url else {
                return nil
            }
            return SearchItem(
                id: "setting:\(setting.pane)",
                title: setting.name,
                subtitle: "System Settings",
                kind: .systemSetting,
                action: .open(url),
                score: score + 2_000,
                fileURL: nil
            )
        }
        .sorted { $0.score > $1.score }

        return SearchItemPage(
            items: Array(matches.prefix(limit)),
            totalMatched: matches.count
        )
    }

    private static func discoverInstalledSettings() -> [Setting] {
        let fileManager = FileManager.default
        let roots: [(url: URL, pathExtension: String, requiresSettingsMarker: Bool)] = [
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

        var discovered: [Setting] = []
        for root in roots {
            let children = (try? fileManager.contentsOfDirectory(
                at: root.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in children
                where url.pathExtension.caseInsensitiveCompare(root.pathExtension) == .orderedSame {
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
                    Setting(
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

        for suffix in [" Settings Extension", " Settings", " Preferences", " Preference Pane"] {
            if name.lowercased().hasSuffix(suffix.lowercased()) {
                name.removeLast(suffix.count)
                break
            }
        }
        return name.isEmpty ? nil : name
    }
}
