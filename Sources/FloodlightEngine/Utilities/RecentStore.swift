import Foundation
import os

package final class RecentStore: @unchecked Sendable {
    private struct Entry: Codable {
        var launches: Int
        var lastOpened: Date
    }

    private let defaults: UserDefaults
    private let key = "recent-items-v1"
    private let entries: OSAllocatedUnfairLock<[String: Entry]>
    private let persistenceQueue = DispatchQueue(
        label: "com.floodlight.recent-items",
        qos: .utility
    )

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = OSAllocatedUnfairLock(initialState: decoded)
        } else {
            entries = OSAllocatedUnfairLock(initialState: [:])
        }
    }

    package func record(_ id: String) {
        persistenceQueue.async { [self] in
            let snapshot = entries.withLock { entries in
                var entry = entries[id] ?? Entry(launches: 0, lastOpened: .distantPast)
                entry.launches += 1
                entry.lastOpened = .now
                entries[id] = entry
                return entries
            }
            persist(snapshot)
        }
    }

    package func boost(for id: String) -> Int {
        entries.withLock { entries in
            guard let entry = entries[id] else { return 0 }
            return Self.boost(for: entry, now: .now)
        }
    }

    private static func boost(for entry: Entry, now: Date) -> Int {
        let age = max(0, now.timeIntervalSince(entry.lastOpened))
        let recency = max(0, 4_000 - Int(age / 900))
        return min(entry.launches, 25) * 200 + recency
    }

    private func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }
}
