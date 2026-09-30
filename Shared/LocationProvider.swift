import Combine
import CoreLocation
import Foundation

// One-shot when-in-use location for the nearby stations (phone and watch;
// the watch inherits the phone app's authorization when paired). The
// permission prompt fires only from the user's explicit button tap (the
// button is the priming context); the fix is used in memory only — never
// stored or transmitted (on-device sort, see NearbyStations).
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle                  // not asked yet — show the button
        case locating
        case located(latitude: Double, longitude: Double)
        case denied                // denied/restricted — point to Settings
    }

    @Published private(set) var state: State = .idle

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Already decided in a previous session? Skip the button.
        switch manager.authorizationStatus {
        case .denied, .restricted:                 state = .denied
        case .authorizedWhenInUse, .authorizedAlways: break // located on demand
        default:                                   break
        }
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    // Button tap (or appearance while already authorized): prompt if needed,
    // then fetch one fix.
    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .locating
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            state = .locating
            manager.requestLocation()
        default:
            state = .denied
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.state == .locating { self.manager.requestLocation() }
            case .denied, .restricted:
                self.state = .denied
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let (latitude, longitude) = (coordinate.latitude, coordinate.longitude)
        Task { @MainActor in
            self.state = .located(latitude: latitude, longitude: longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            // Fall back to the button rather than an error screen — nearby is
            // a suggestion, not a core flow.
            if self.state == .locating { self.state = .idle }
        }
    }
}
