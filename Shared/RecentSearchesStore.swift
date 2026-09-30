import Foundation
import Combine

// Recent search terms, most-recent first. Used only by the iOS app (lives in
// Shared so it can be unit-tested). Case-insensitive dedup, capped at `limit`.
// `defaults` is injectable so tests can use an isolated suite.
@MainActor
final class RecentSearchesStore: ObservableObject {
    @Published private(set) var searches: [String]

    private let key = "recentSearches"
    private let limit = 10
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        searches = defaults.stringArray(forKey: key) ?? []
    }

    func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = searches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        searches = Array(updated.prefix(limit))
        persist()
    }

    func remove(_ query: String) {
        searches.removeAll { $0 == query }
        persist()
    }

    func clear() {
        searches = []
        persist()
    }

    private func persist() {
        defaults.set(searches, forKey: key)
    }
}
