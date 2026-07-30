import Foundation

final class RecentStore: @unchecked Sendable {
    private struct Entry: Codable {
        var launches: Int
        var lastOpened: Date
    }

    private let defaults: UserDefaults
    private let key = "recent-items-v1"
    private let lock = NSLock()
    private var entries: [String: Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func record(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[id] ?? Entry(launches: 0, lastOpened: .distantPast)
        entry.launches += 1
        entry.lastOpened = .now
        entries[id] = entry
        persist()
    }

    func boost(for id: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else { return 0 }
        let age = max(0, Date().timeIntervalSince(entry.lastOpened))
        let recency = max(0, 4_000 - Int(age / 900))
        return min(entry.launches, 25) * 200 + recency
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
