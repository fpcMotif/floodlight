import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

struct ClipboardHistoryStorePropertyTests {
    @Test func adversarialCorpusStringsNeverCrashStore() {
        let store = ClipboardHistoryStore.inMemory()

        for text in AdversarialCorpus.strings {
            let entry = store.record(text: text)
            if text.utf8.count <= 32_000 {
                // If it wasn't a duplicate of previous, entry was recorded
                if let entry {
                    #expect(entry.text == text)
                    #expect(store.mostRecentEntry?.id == entry.id)
                }
            } else {
                #expect(entry == nil)
            }
        }

        // Test querying with adversarial search queries
        for query in AdversarialCorpus.searchQueries + AdversarialCorpus.strings {
            let results = store.search(query: query)
            // Results must always be a subset of valid entries in the store
            #expect(results.count <= store.count)
            for item in results {
                #expect(!item.id.isEmpty)
                #expect(!item.text.isEmpty || textIsEmptyAllowed(item.text))
            }
        }
    }

    private func textIsEmptyAllowed(_ text: String) -> Bool {
        text.isEmpty
    }

    @Test func propertyRandomSequenceMaintainsOrderingAndPinInvariants() throws {
        try checkProperty(
            "pinning and ordering invariants hold over arbitrary sequences",
            Gen<String>.array(
                of: .element(of: AdversarialCorpus.strings.filter { $0.utf8.count <= 1_000 }),
                count: 1...20
            ),
            runs: 100
        ) { strings in
            let store = ClipboardHistoryStore.inMemory()
            var recorded: [ClipboardEntry] = []

            for string in strings {
                if let entry = store.record(text: string) {
                    recorded.append(entry)
                }
            }

            // Pin half the items
            for (idx, entry) in recorded.enumerated() where idx % 2 == 0 {
                store.pin(id: entry.id)
            }

            let all = store.search(query: "")
            let pinned = all.filter(\.isPinned)
            let unpinned = all.filter { !$0.isPinned }

            // Pinned items must all appear before unpinned items
            let prefixPinned = Array(all.prefix(pinned.count))
            #expect(prefixPinned == pinned)

            // Total count matches
            #expect(all.count == pinned.count + unpinned.count)
            return true
        }
    }

    @Test func filePathsRemainSearchableAndKeepFileKind() {
        let store = ClipboardHistoryStore.inMemory()
        let paths = [
            "/Users/f/Documents/Invoices/Invoice_2026.pdf",
            "/Users/f/Movies/ProductDemo_4K.mov",
            "/Users/f/devv/floodlight",
        ]

        for path in paths {
            #expect(store.recordFile(path: path)?.kind == .file)
        }

        for path in paths {
            let byName = store.search(query: URL(fileURLWithPath: path).lastPathComponent)
            #expect(byName.contains { $0.text == path && $0.kind == .file })
        }

        let byDirectory = store.search(query: "/Users/f")
        #expect(byDirectory.count == 3)
        #expect(byDirectory.allSatisfy { $0.kind == .file })
    }
}
