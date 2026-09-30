import Testing
@testable import HissiCore

@Suite struct ElevatorStatusTests {
    @Test func mapsIsWorking() {
        #expect(ElevatorStatus(isWorking: true) == .working)
        #expect(ElevatorStatus(isWorking: false) == .broken)
        #expect(ElevatorStatus(isWorking: nil) == .unknown)
    }

    // Symbols must differ by shape, not only colour — the a11y contract.
    @Test func symbolsAreDistinctPerStatus() {
        let symbols = Set([ElevatorStatus.working, .broken, .unknown].map(\.symbolName))
        #expect(symbols.count == 3)
    }

    @Test func labelsAreDistinctPerStatus() {
        let labels = Set([ElevatorStatus.working, .broken, .unknown].map(\.label))
        #expect(labels.count == 3)
        let short = Set([ElevatorStatus.working, .broken, .unknown].map(\.shortLabel))
        #expect(short.count == 3)
    }
}
