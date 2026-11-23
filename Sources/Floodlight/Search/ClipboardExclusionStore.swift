import Foundation
import os

final class ClipboardExclusionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "clipboard-exclusions-v1"
    private let exclusions: OSAllocatedUnfairLock<Set<String>>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data)
        {
            exclusions = OSAllocatedUnfairLock(initialState: decoded)
        } else {
            exclusions = OSAllocatedUnfairLock(initialState: [])
        }
    }

    var excludedBundleIDs: [String] {
        exclusions.withLock { $0.sorted() }
    }

    func exclude(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = exclusions.withLock { set -> [String] in
            set.insert(trimmed)
            return Array(set)
        }
        persist(snapshot)
    }

    func unexclude(bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let snapshot = exclusions.withLock { set -> [String] in
            set.remove(trimmed)
            return Array(set)
        }
        persist(snapshot)
    }

    func isExcluded(bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return exclusions.withLock { $0.contains(trimmed) }
    }

    private func persist(_ list: [String]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
}
