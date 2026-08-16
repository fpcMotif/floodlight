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
        case "name":
            self = .name(value)
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
    private struct State: Codable, Sendable {
        var rules: Set<BlocklistRule> = []
        var normalizedBlockedNames: Set<String> = []
        var blockedIDs: Set<String> = []

        mutating func insert(_ rule: BlocklistRule) {
            rules.insert(rule)
            switch rule {
            case let .name(name):
                normalizedBlockedNames.insert(name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ))
            case let .id(id):
                blockedIDs.insert(id)
            }
        }

        mutating func remove(_ rule: BlocklistRule) {
            rules.remove(rule)
            switch rule {
            case let .name(name):
                normalizedBlockedNames.remove(name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ))
            case let .id(id):
                blockedIDs.remove(id)
            }
        }

        func isBlocked(name: String, id: String) -> Bool {
            if blockedIDs.contains(id) { return true }
            if !normalizedBlockedNames.isEmpty {
                let normalized = name.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                if normalizedBlockedNames.contains(normalized) { return true }
            }
            return false
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

    package func isBlocked(name: String, id: String) -> Bool {
        state.withLock { $0.isBlocked(name: name, id: id) }
    }

    private func persist(_ rules: [BlocklistRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: key)
    }
}
