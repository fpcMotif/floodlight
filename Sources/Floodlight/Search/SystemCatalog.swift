import Foundation

enum SystemCatalog {
    private struct Setting {
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

    private static let settings = [
        Setting(name: "Accessibility", keywords: "voiceover zoom display motor hearing", pane: "com.apple.Accessibility-Settings.extension"),
        Setting(name: "Apple Account", keywords: "icloud account profile", pane: "AppleIDPrefPane"),
        Setting(name: "Bluetooth", keywords: "devices headphones keyboard mouse", pane: "com.apple.BluetoothSettings"),
        Setting(name: "Control Center", keywords: "menu bar widgets", pane: "com.apple.ControlCenter-Settings.extension"),
        Setting(name: "Date & Time", keywords: "clock timezone calendar", pane: "com.apple.Date-Time-Settings.extension"),
        Setting(name: "Desktop & Dock", keywords: "wallpaper mission control stage manager dock", pane: "com.apple.Desktop-Settings.extension"),
        Setting(name: "Displays", keywords: "monitor resolution brightness night shift", pane: "com.apple.Displays-Settings.extension"),
        Setting(name: "General", keywords: "about software update storage airdrop handoff login items", pane: "com.apple.systempreferences.GeneralSettings"),
        Setting(name: "Keyboard", keywords: "input text shortcuts dictation", pane: "com.apple.Keyboard-Settings.extension"),
        Setting(name: "Lock Screen", keywords: "password screensaver sleep", pane: "com.apple.Lock-Screen-Settings.extension"),
        Setting(name: "Mouse", keywords: "tracking scrolling click", pane: "com.apple.Mouse-Settings.extension"),
        Setting(name: "Network", keywords: "wifi ethernet vpn firewall", pane: "com.apple.Network-Settings.extension"),
        Setting(name: "Notifications", keywords: "alerts focus badges", pane: "com.apple.Notifications-Settings.extension"),
        Setting(name: "Privacy & Security", keywords: "location camera microphone full disk access", pane: "com.apple.settings.PrivacySecurity.extension"),
        Setting(name: "Screen Saver", keywords: "wallpaper lock", pane: "com.apple.ScreenSaver-Settings.extension"),
        Setting(name: "Siri & Spotlight", keywords: "assistant search indexing shortcuts", pane: "com.apple.Siri-Settings.extension"),
        Setting(name: "Sound", keywords: "volume output input alert", pane: "com.apple.Sound-Settings.extension"),
        Setting(name: "Trackpad", keywords: "gestures click scroll", pane: "com.apple.Trackpad-Settings.extension"),
        Setting(name: "Users & Groups", keywords: "accounts login password", pane: "com.apple.Users-Groups-Settings.extension")
    ]

    static func search(_ query: String, limit: Int = 6) -> [SearchItem] {
        guard !query.isEmpty else { return [] }
        let normalizedQuery = FuzzyMatcher.normalized(query)
        return settings.compactMap { setting -> SearchItem? in
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
        .prefix(limit)
        .map { $0 }
    }
}
