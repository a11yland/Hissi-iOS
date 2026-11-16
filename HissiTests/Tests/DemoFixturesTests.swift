import Testing
import Foundation
@testable import HissiCore

// The screenshot catalog, over the real bundled seed (the test package
// bundles no resources, so it is read from the source tree).
struct DemoFixturesTests {
    private let seed = SeedCatalog.parse(try! Data(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Shared/Resources/seed-catalog.json")))
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Alexanderplatz — the location scripts/screenshots.sh sets.
    private let latitude = 52.5219, longitude = 13.4132

    private var catalog: [AccessibilityCloudClient.Equipment] {
        DemoFixtures.catalog(seed: seed, now: now, language: "de")
    }

    @Test func everySeedRecordGetsANumericId() {
        #expect(catalog.allSatisfy { Int($0.id) != nil })
        #expect(Set(catalog.map(\.id)).count == catalog.count)
    }

    @Test func everyCuratedPickExists() {
        for pick in DemoFixtures.broken + DemoFixtures.unknown + DemoFixtures.favoritePicks {
            #expect(seed.contains { pick.matches($0) }, "\(pick.station) / \(pick.description)")
        }
    }

    @Test func statusesAreCurated() {
        #expect(catalog.filter { $0.isWorking == false }.count == DemoFixtures.broken.count)
        #expect(catalog.filter { $0.isWorking == nil }.count == DemoFixtures.unknown.count)
        #expect(catalog.filter { $0.isWorking == false }.allSatisfy { $0.stateExplanation != nil })
        // Fresh enough never to trip the stale-data warning.
        #expect(catalog.compactMap(\.lastUpdate).allSatisfy { now.timeIntervalSince($0) < 86_400 * 2 })
    }

    // The overlay must answer every seed record with its demo counterpart,
    // not append status-unknown duplicates next to it — only the records
    // sharing an inventory number come back, once each.
    @Test func overlayAddsNoSeedDuplicates() {
        let overlaid = EquipmentCatalog.overlaid(live: catalog, seed: seed, stations: [])
        let demoIds = Set(catalog.map(\.id))
        let added = overlaid.filter { !demoIds.contains($0.id) }
        let numbers = seed.compactMap(\.fastaEquipmentNumber)
        let shared = Set(numbers.filter { number in numbers.filter { $0 == number }.count > 1 })
        #expect(added.count == overlaid.count - catalog.count)
        #expect(added.allSatisfy { $0.isWorking == nil && shared.contains($0.fastaEquipmentNumber ?? 0) })
    }

    @Test func favoritesStartWithOneBrokenElevator() {
        let favorites = DemoFixtures.favorites(from: catalog, now: now)
        #expect(favorites.count == DemoFixtures.favoritePicks.count)
        #expect(favorites.filter { $0.isWorking == false }.count == 1)
        #expect(favorites.map(\.addedAt) == favorites.map(\.addedAt).sorted(by: { $0! > $1! }))
    }

    @Test func nearbyShowsABrokenStation() {
        let stations = NearbyStations.nearest(toLatitude: latitude, longitude: longitude, in: catalog)
        #expect(stations.count >= 3)
        #expect(stations.contains { $0.status == .broken })
    }
}
