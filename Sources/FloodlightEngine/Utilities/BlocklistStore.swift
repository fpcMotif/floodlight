import Foundation
import os

package enum BlocklistRule: Codable, Hashable, Sendable {
    case name(String)
    case id(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        switch type {
        case "id":
            self = .id(value)
        default:
            self = .name(value)
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .name(value):
            try container.encode("name", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .id(value):
            try container.encode("id", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

package final class BlocklistStore: @unchecked Sendable {
    private struct State: Sendable {
        var rules: Set<BlocklistRule> = []
        var normalizedBlockedNames: Set<String> = []
        var blockedIDs: Set<String> = []

        mutating func insert(_ rule: BlocklistRule) {
            rules.insert(rule)
            switch rule {
            case let .name(name):
                normalizedBlockedNames.insert(FuzzyMatcher.normalized(name))
            case let .id(id):
                blockedIDs.insert(id)
            }
        }

        mutating func remove(_ rule: BlocklistRule) {
            rules.remove(rule)
            switch rule {
            case let .name(name):
                normalizedBlockedNames.remove(FuzzyMatcher.normalized(name))
            case let .id(id):
                blockedIDs.remove(id)
            }
        }

        /// The one predicate. Rules are stored folded, so a caller that has
        /// already folded — the catalog, which normalizes at discovery — asks
        /// this directly and folds nothing per query.
        func isBlocked(normalizedName: String, id: String) -> Bool {
            blockedIDs.contains(id) || normalizedBlockedNames.contains(normalizedName)
        }
    }

    private let defaults: UserDefaults
    private let key = "search-blocklist-v1"
    private let state: OSAllocatedUnfairLock<State>

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([BlocklistRule].self, from: data)
        {
            var initialState = State()
            for rule in decoded {
                initialState.insert(rule)
            }
            state = OSAllocatedUnfairLock(initialState: initialState)
        } else {
            state = OSAllocatedUnfairLock(initialState: State())
        }
    }

    package var rules: [BlocklistRule] {
        state.withLock { Array($0.rules) }
    }

    package func block(name: String) {
        let rule = BlocklistRule.name(name)
        let rulesToPersist = state.withLock { state -> [BlocklistRule] in
            state.insert(rule)
            return Array(state.rules)
        }
        persist(rulesToPersist)
    }

    package func block(id: String) {
        let rule = BlocklistRule.id(id)
        let rulesToPersist = state.withLock { state -> [BlocklistRule] in
            state.insert(rule)
            return Array(state.rules)
        }
        persist(rulesToPersist)
    }

    package func unblock(name: String) {
        let rule = BlocklistRule.name(name)
        let rulesToPersist = state.withLock { state -> [BlocklistRule] in
            state.remove(rule)
            return Array(state.rules)
        }
        persist(rulesToPersist)
    }

    package func unblock(id: String) {
        let rule = BlocklistRule.id(id)
        let rulesToPersist = state.withLock { state -> [BlocklistRule] in
            state.remove(rule)
            return Array(state.rules)
        }
        persist(rulesToPersist)
    }

    /// Whether a candidate is excluded, for callers holding only a display
    /// name — the publication path, which sees a page of results rather than
    /// the catalog behind them.
    ///
    /// Folding allocates, and this runs per candidate per keystroke, so it is
    /// skipped entirely when no name rule exists to match. An id rule still
    /// answers without it.
    package func isBlocked(name: String, id: String) -> Bool {
        state.withLock { state in
            if state.blockedIDs.contains(id) { return true }
            guard !state.normalizedBlockedNames.isEmpty else { return false }
            return state.isBlocked(normalizedName: FuzzyMatcher.normalized(name), id: id)
        }
    }

    /// The same question from a caller that already holds the folded name.
    ///
    /// `normalizedName` must come from `FuzzyMatcher.normalized` — the same
    /// call the store folds its own name rules with, which is what keeps name
    /// rules case- and diacritic-insensitive without folding anything on the
    /// query path. The catalog asks this one, after the mask and the matcher
    /// have already rejected everything the query never matched.
    package func isBlocked(normalizedName: String, id: String) -> Bool {
        state.withLock { $0.isBlocked(normalizedName: normalizedName, id: id) }
    }

    private func persist(_ rules: [BlocklistRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }
}
