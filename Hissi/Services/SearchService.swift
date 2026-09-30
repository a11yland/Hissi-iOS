import Combine
import Foundation
import SwiftUI

@MainActor
class SearchService: ObservableObject {
    @Published var regions: [RegionGroup] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasSearched = false

    // The detail view refreshed one search result (a targeted request, see
    // ElevatorDetailView) — the row behind it shows the same state, so the
    // list and the detail never disagree.
    func apply(_ refreshed: MonitoredElevator, replacing id: String) {
        withAnimation { regions = SearchGrouping.replacing(regions, id: id, with: refreshed) }
    }

    func clear() {
        regions = []
        hasSearched = false
        errorMessage = nil
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            regions = []
            hasSearched = false
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        hasSearched = true
        // Every keystroke cancels the previous search — a superseded search
        // must not write its (empty/failed) result over the newer one's state.
        defer {
            if !Task.isCancelled {
                withAnimation { isLoading = false }
            }
        }

        // Phase 1, instant: results from the persisted/cached catalog, which
        // may be stale (a cold build takes 30–60 s of pure server time) —
        // names are stable, statuses correct themselves in phase 2. On the
        // very first launch no snapshot exists yet; the bundled seed then
        // previews names (status unknown) instead of a bare spinner while the
        // first build runs. Preview results are favoritable: a favorite
        // created from a seed record's id bridges to its live record via the
        // operator inventory number on the next refresh
        // (EquipmentCatalog.equipment(for:)) and adopts the live id.
        let snapshot = await EquipmentCatalog.shared.snapshot()
        guard !Task.isCancelled else { return }
        if let snapshot {
            let grouped = SearchGrouping.group(AccessibilityCloudClient.matchStations(trimmed, in: snapshot))
            withAnimation { regions = grouped }
        } else {
            let seed = EquipmentCatalog.overlaid(live: [], seed: SeedCatalog.records)
            if !seed.isEmpty {
                let grouped = SearchGrouping.group(AccessibilityCloudClient.matchStations(trimmed, in: seed))
                withAnimation { regions = grouped }
            }
        }

        // Phase 2, fresh: awaits the shared rebuild when the snapshot was
        // stale, then re-renders with live statuses.
        guard let matches = await AccessibilityCloudClient.searchStations(trimmed) else {
            guard !Task.isCancelled else { return }
            // Stale results beat an error screen; the error only shows when
            // there is nothing to show at all.
            if regions.isEmpty {
                errorMessage = String(localized: "Suche fehlgeschlagen.")
            }
            return
        }
        guard !Task.isCancelled else { return }
        // Animated: rows morph instead of hard-swapping when statuses land.
        let grouped = SearchGrouping.group(matches)
        withAnimation { regions = grouped }
    }
}
