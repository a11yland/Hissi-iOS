import Testing
import Foundation
@testable import HissiCore

@MainActor
@Suite struct RecentSearchesTests {
    // Isolated defaults suite per store so tests don't touch each other or
    // the real app domain.
    private func makeStore() -> RecentSearchesStore {
        let defaults = UserDefaults(suiteName: "recent-\(UUID().uuidString)")!
        return RecentSearchesStore(defaults: defaults)
    }

    @Test func addPrependsMostRecent() {
        let store = makeStore()
        store.add("Alexanderplatz")
        store.add("Zoo")
        #expect(store.searches == ["Zoo", "Alexanderplatz"])
    }

    @Test func dedupIsCaseInsensitiveAndMovesToFront() {
        let store = makeStore()
        store.add("Alex")
        store.add("Zoo")
        store.add("alex")
        // Single entry, moved to the front, keeping the newest casing.
        #expect(store.searches == ["alex", "Zoo"])
    }

    @Test func trimsWhitespaceAndIgnoresBlank() {
        let store = makeStore()
        store.add("  Alex  ")
        store.add("   ")
        #expect(store.searches == ["Alex"])
    }

    @Test func capsAtLimit() {
        let store = makeStore()
        for i in 0..<15 { store.add("q\(i)") }
        #expect(store.searches.count == 10)
        #expect(store.searches.first == "q14")
        #expect(store.searches.last == "q5")
    }

    @Test func removeAndClear() {
        let store = makeStore()
        store.add("A")
        store.add("B")
        store.remove("A")
        #expect(store.searches == ["B"])
        store.clear()
        #expect(store.searches.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "recent-\(UUID().uuidString)")!
        RecentSearchesStore(defaults: defaults).add("Alexanderplatz")
        let reloaded = RecentSearchesStore(defaults: defaults)
        #expect(reloaded.searches == ["Alexanderplatz"])
    }
}
