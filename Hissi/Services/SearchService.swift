import Combine
import Foundation
import SwiftUI

@MainActor
class SearchService: ObservableObject {
    @Published var regions: [RegionGroup] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var hasSearched = false

    // What the current query has gathered so far, re-grouped on every landing:
    // the local catalog the VBB results are filtered from (snapshot, seed or
    // the fresh build) and the national API's matches (nil until they land).
    private var localCatalog: [AccessibilityCloudClient.Equipment]?
    private var nationalMatches: [AccessibilityCloudClient.Equipment]?

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
        localCatalog = nil
        nationalMatches = nil
    }

    // What one of the two parallel lookups brings back.
    private enum Landing {
        case local([AccessibilityCloudClient.Equipment]?)
        case national([AccessibilityCloudClient.Equipment]?)
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return
        }

        isLoading = true
        errorMessage = nil
        hasSearched = true
        nationalMatches = nil
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
            localCatalog = snapshot
        } else {
            let seed = EquipmentCatalog.overlaid(live: [], seed: SeedCatalog.records)
            localCatalog = seed.isEmpty ? nil : seed
        }
        render(trimmed)

        // Phase 2, fresh, and the national lookup side by side: the shared
        // rebuild (awaited when the snapshot was stale) re-renders the VBB
        // results with live statuses; the Aufzugsstatus API answers for the
        // rest of the country — a quick request that must not wait behind a
        // 30 s catalog build, and a slow build that must not wait for it
        // either. Each re-groups the results as it lands.
        var localFailed = false
        var nationalFailed = false
        await withTaskGroup(of: Landing.self) { group in
            group.addTask { .local(await EquipmentCatalog.shared.all()) }
            group.addTask { .national(await AufzugsstatusClient.searchLifts(matching: trimmed)) }
            for await landing in group {
                guard !Task.isCancelled else { return }
                switch landing {
                case .local(let catalog):
                    if let catalog { localCatalog = catalog } else { localFailed = true }
                case .national(let matches):
                    if let matches { nationalMatches = matches } else { nationalFailed = true }
                }
                render(trimmed)
            }
        }
        guard !Task.isCancelled else { return }
        // Stale results beat an error screen; the error only shows when there
        // is nothing to show at all — a failed national lookup next to VBB
        // results (or the other way round) is silent, the other source's
        // rows are the answer.
        if regions.isEmpty, localFailed || nationalFailed {
            errorMessage = String(localized: "Suche fehlgeschlagen.")
        }
    }

    // Groups whatever has landed: the VBB matches from the local catalog plus
    // the national matches minus the DB records the local catalog already
    // shows (AufzugsstatusClient.excludingKnown). Animated: rows morph
    // instead of hard-swapping when a source lands.
    private func render(_ query: String) {
        let local = localCatalog.map { AccessibilityCloudClient.matchStations(query, in: $0) } ?? []
        let national = AufzugsstatusClient.excludingKnown(
            nationalMatches ?? [],
            knownInventoryNumbers: AufzugsstatusClient.knownInventoryNumbers(in: localCatalog ?? [])
        )
        let grouped = SearchGrouping.group(local + national)
        withAnimation { regions = grouped }
    }
}
