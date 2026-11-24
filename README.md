# Hissi

A minimal iOS app that monitors the status of user-selected elevators in the Berlin/Brandenburg public transit network and at Deutsche Bahn stations across Germany, using the [transit.accessibility.cloud](https://transit.accessibility.cloud) API.

## Features

- Search stations (Berlin/Brandenburg, plus Deutsche Bahn stations nationwide) and star the elevators you want to watch — favorites start empty and are managed on the iPhone
- Three-state status per elevator (in service / out of service / unknown), shown with a distinct **shape and** colour so it stays legible for colour-blind users and in monochrome contexts
- Distinguishes when the app last polled ("Geprüft …") from how fresh the source data is ("Stand …")
- Detail view shows the source, operating organization, disruption reason (while broken) and a map snippet of the station — tap it to open in Apple Maps; on iPhone in landscape the fields and map render as two columns
- Auto-refreshes every 30 minutes, on foreground, and via a background app refresh that keeps the widget and complications current between sessions
- Pull-to-refresh plus a toolbar refresh button
- Home screen widgets — „Aufzug-Status" (small, medium) and „Alle Favoriten" (large) — plus Lock Screen widgets (circular, rectangular, inline)
- Companion Apple Watch app — browse elevators with the Digital Crown — plus watch-face complications and a Smart Stack widget
- Ready-made shortcuts for Siri, Spotlight and the Shortcuts app — ask for the overall status or a single favorite without opening the app
- Session-only light/dark toggle
- Custom app icon (light, dark and tinted variants)

## Requirements

- iOS 18.0+ / watchOS 10.0+
- Xcode 26.5+

## Setup

1. Copy `Secrets.example.swift` to `Shared/Secrets.swift` and fill in a transit.accessibility.cloud `appToken` (the file is gitignored).
2. Open `Hissi.xcodeproj` and run the `Hissi` scheme on a simulator or device. No dependencies, no package manager.

The project ships with four targets — `Hissi` (iOS app), `HissiWidget` (iOS widget extension), `HissiWatch` (watchOS app) and `HissiWatchWidget` (watch complications). The widget, watch app and complications are embedded into the iOS app at build time, so installing the iOS app makes them all available.

Favorites, cache and recent searches are shared across targets via an App Group (`group.com.a11yland.Hissi`). The **iPhone is the only place favorites are created**; the widget, watch and complications are read-only mirrors. See [`docs/architecture.md`](docs/architecture.md) for the data-flow diagram.

## Tests

Unit tests live in `HissiTests/` as a standalone Swift Package (`HissiCore`) and run on macOS:

```bash
swift test --package-path HissiTests
```

## Data source

Elevator status is provided by the [transit.accessibility.cloud](https://transit.accessibility.cloud) API (flat Elevators/StatusSpans/StopPlaces lists, joined locally by id). accessibility.cloud and [brokenlifts.org](https://brokenlifts.org) are projects by [Sozialhelden e.V.](https://sozialhelden.de) Station names and locations in the bundled seed come from [DELFI e.V.](https://www.delfi.de) via [gtfs.de](https://gtfs.de) (CC BY 4.0) and the [VBB](https://www.vbb.de) GTFS (CC BY); the elevators and stops of the municipal networks in Nordrhein-Westfalen in the seed from the [VRR infrastructure API](https://www.opendata-oepnv.de/ht/de/api) (Verkehrsverbund Rhein-Ruhr AöR, CC BY 4.0; behind a feature toggle until their live status ships); federal states from the BKG VG250 borders (© GeoBasis-DE / BKG, dl-de/by-2-0).
