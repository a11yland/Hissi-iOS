#!/usr/bin/env python3
"""Compare two seed catalogs and report drift (used by the Seed update workflow).

    python3 scripts/diff-seed-catalog.py <bundled.json> <fresh.json>

Prints a Markdown summary of added/removed/changed elevators and stations and
exits 1 when the catalogs differ. Ignored: `generatedAt` (always differs),
coordinates (source jitter would cause weekly noise; they don't affect search
or the station a record belongs to) and `legacyIds` (derived, only ever
shrinks). A format change (bundled seed older than the fresh one) is always
drift.
"""

import json
import sys
import traceback
from pathlib import Path

ELEVATOR_FIELDS = [
    "inventoryId", "stationId", "stationName", "stationModes", "region",
    "description", "sourceName", "organizationName",
]
STATION_FIELDS = ["name", "region", "dhid"]


def load(path: str) -> tuple[int, dict[str, dict], dict[str, dict]]:
    file = json.loads(Path(path).read_text())
    return (
        file.get("version", 1),
        {r["id"]: r for r in file["elevators"]},
        {s["stationId"]: s for s in file.get("stations", [])},
    )


def seed_sort_key(elevator_id: str) -> tuple:
    # Numeric (transit.accessibility.cloud) ids first, in numeric order;
    # other sources ("vrr:…") after them, by id — as the generator sorts.
    return (0, int(elevator_id), "") if elevator_id.isdigit() else (1, 0, elevator_id)


def describe(record: dict) -> str:
    return f"`{record['id']}` — {record.get('stationName', '?')}: {record.get('description', '')}"


def changes(old: dict, new: dict, fields: list[str]) -> list[str]:
    return [f"{field}: `{old.get(field)}` → `{new.get(field)}`"
            for field in fields if old.get(field) != new.get(field)]


def main() -> int:
    (old_version, bundled, bundled_stations) = load(sys.argv[1])
    (new_version, fresh, fresh_stations) = load(sys.argv[2])

    if old_version != new_version:
        print(f"## Seed format {old_version} → {new_version}\n")
        print(f"{len(fresh)} elevators at {len(fresh_stations)} stations "
              f"(bundled: {len(bundled)} elevators, {len(bundled_stations)} stations).")
        return 1

    added = [fresh[i] for i in sorted(fresh.keys() - bundled.keys(), key=seed_sort_key)]
    removed = [bundled[i] for i in sorted(bundled.keys() - fresh.keys(), key=seed_sort_key)]
    changed = [(bundled[i], d) for i in sorted(bundled.keys() & fresh.keys(), key=seed_sort_key)
               if (d := changes(bundled[i], fresh[i], ELEVATOR_FIELDS))]
    stations_added = [fresh_stations[i] for i in sorted(fresh_stations.keys() - bundled_stations.keys())]
    stations_removed = [bundled_stations[i] for i in sorted(bundled_stations.keys() - fresh_stations.keys())]
    stations_changed = [(bundled_stations[i], d) for i in sorted(bundled_stations.keys() & fresh_stations.keys())
                        if (d := changes(bundled_stations[i], fresh_stations[i], STATION_FIELDS))]

    if not (added or removed or changed or stations_added or stations_removed or stations_changed):
        print("No drift — bundled seed matches a fresh generation.")
        return 0

    print(f"## Seed drift: {len(added)} added, {len(removed)} removed, {len(changed)} changed elevators; "
          f"{len(stations_added)} added, {len(stations_removed)} removed, "
          f"{len(stations_changed)} changed stations\n")
    for title, records in (("Elevators added", added), ("Elevators removed", removed)):
        if records:
            print(f"### {title} ({len(records)})\n")
            for r in records:
                print(f"- {describe(r)}")
            print()
    if changed:
        print(f"### Elevators changed ({len(changed)})\n")
        for record, diffs in changed:
            print(f"- {describe(record)}")
            for d in diffs:
                print(f"  - {d}")
        print()
    for title, stations in (("Stations added", stations_added), ("Stations removed", stations_removed)):
        if stations:
            print(f"### {title} ({len(stations)})\n")
            for s in stations:
                print(f"- `{s['stationId']}` — {s.get('name', '?')}")
            print()
    if stations_changed:
        print(f"### Stations changed ({len(stations_changed)})\n")
        for station, diffs in stations_changed:
            print(f"- `{station['stationId']}` — {station.get('name')}")
            for d in diffs:
                print(f"  - {d}")
        print()
    return 1


if __name__ == "__main__":
    # 0 = no drift, 1 = drift. Crashes exit 2 so the workflow can tell a
    # failed comparison apart from a drifted one.
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(2)
