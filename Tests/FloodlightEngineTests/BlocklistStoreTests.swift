import Foundation
import os
import Testing
@testable import FloodlightEngine

struct BlocklistStoreTests {
    @Test func newlyCreatedStoreIsEmptyByDefault() throws {
        let suiteName = "BlocklistStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlocklistStore(defaults: defaults)
        #expect(store.rules.isEmpty)
        #expect(!store.isBlocked(name: "Claude", id: "application:/Applications/Claude.app"))
    }

    @Test func blockedNameExcludesCaseInsensitively() throws {
        let suiteName = "BlocklistStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlocklistStore(defaults: defaults)
        store.block(name: "Clash")

        #expect(store.isBlocked(name: "Clash", id: "application:/Applications/Clash.app"))
        #expect(store.isBlocked(name: "clash", id: "application:/Applications/Clash.app"))
        #expect(store.isBlocked(name: "CLASH", id: "application:/Applications/Clash.app"))
        #expect(!store.isBlocked(name: "Claude", id: "application:/Applications/Claude.app"))
    }

    @Test func blockedIDExcludesExactIdentifier() throws {
        let suiteName = "BlocklistStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlocklistStore(defaults: defaults)
        let targetID = "application:/Applications/Utilities/Helper.app"
        store.block(id: targetID)

        #expect(store.isBlocked(name: "Helper", id: targetID))
        #expect(!store.isBlocked(name: "Helper", id: "application:/Applications/Helper.app"))
    }

    @Test func unblockingRestoresSearchability() throws {
        let suiteName = "BlocklistStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BlocklistStore(defaults: defaults)
        store.block(name: "Clash")
        #expect(store.isBlocked(name: "Clash", id: "application:/Applications/Clash.app"))

        store.unblock(name: "Clash")
        #expect(!store.isBlocked(name: "Clash", id: "application:/Applications/Clash.app"))
    }

    @Test func blocklistPersistsAcrossInstances() throws {
        let suiteName = "BlocklistStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = BlocklistStore(defaults: defaults)
        store1.block(name: "Clash")
        store1.block(id: "application:/Applications/Noise.app")

        let store2 = BlocklistStore(defaults: defaults)
        #expect(store2.isBlocked(name: "Clash", id: "application:/Applications/Clash.app"))
        #expect(store2.isBlocked(name: "Noise", id: "application:/Applications/Noise.app"))
    }
}
